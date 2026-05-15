#include "tools/agentkit_ish_session.h"
#include "tools/agentkit_ish_runtime.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

struct agentkit_ish_session {
    pthread_t thread;
    pthread_mutex_t lock;
    pthread_mutex_t lifecycle_lock;
    int input_write_fd;
    int input_read_fd;
    int output_read_fd;
    int output_write_fd;
    char *fakefs_path;
    char *workspace_path;
    uint64_t next_command_id;
    int shell_status;
    bool started;
    bool closed;
    bool shell_exited;
};

struct shell_thread_args {
    struct agentkit_ish_session *session;
};

static char *agentkit_strdup_printf(const char *format, ...) {
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        va_end(args);
        return NULL;
    }
    char *value = malloc((size_t)needed + 1);
    if (value != NULL)
        vsnprintf(value, (size_t)needed + 1, format, args);
    va_end(args);
    return value;
}

static void set_error(char **out_error, const char *format, ...) {
    if (out_error == NULL)
        return;
    va_list args;
    va_start(args, format);
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(NULL, 0, format, copy);
    va_end(copy);
    if (needed < 0) {
        *out_error = NULL;
        va_end(args);
        return;
    }
    *out_error = malloc((size_t)needed + 1);
    if (*out_error != NULL)
        vsnprintf(*out_error, (size_t)needed + 1, format, args);
    va_end(args);
}

static int write_all(int fd, const char *text) {
    size_t remaining = strlen(text);
    const char *cursor = text;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0) {
            if (errno == EINTR)
                continue;
            return -1;
        }
        cursor += written;
        remaining -= (size_t)written;
    }
    return 0;
}

static int64_t now_ms(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (int64_t)tv.tv_sec * 1000 + tv.tv_usec / 1000;
}

static int append_bytes(char **buffer, size_t *used, size_t *capacity, const char *chunk, size_t chunk_size) {
    if (*used + chunk_size + 1 > *capacity) {
        size_t next = *capacity == 0 ? 8192 : *capacity;
        while (*used + chunk_size + 1 > next)
            next *= 2;
        char *grown = realloc(*buffer, next);
        if (grown == NULL)
            return -1;
        *buffer = grown;
        *capacity = next;
    }
    memcpy(*buffer + *used, chunk, chunk_size);
    *used += chunk_size;
    (*buffer)[*used] = '\0';
    return 0;
}

static void record_shell_exit(struct agentkit_ish_session *session, int status) {
    pthread_mutex_lock(&session->lifecycle_lock);
    session->shell_status = status;
    session->shell_exited = true;
    pthread_mutex_unlock(&session->lifecycle_lock);
}

static bool shell_exit_status(struct agentkit_ish_session *session, int *out_status) {
    pthread_mutex_lock(&session->lifecycle_lock);
    bool exited = session->shell_exited;
    if (exited && out_status != NULL)
        *out_status = session->shell_status;
    pthread_mutex_unlock(&session->lifecycle_lock);
    return exited;
}

static char *remove_marker_line(const char *buffer, const char *marker, int *out_status) {
    char *marker_start = (char *)buffer;
    for (;;) {
        marker_start = strstr(marker_start, marker);
        if (marker_start == NULL)
            return NULL;

        bool starts_line = marker_start == buffer || marker_start[-1] == '\n' || marker_start[-1] == '\r';
        char *status_start = marker_start + strlen(marker);
        if (*status_start == ':')
            status_start++;
        bool has_status = (*status_start == '-' && status_start[1] >= '0' && status_start[1] <= '9') ||
            (*status_start >= '0' && *status_start <= '9');
        if (starts_line && has_status)
            break;

        marker_start += strlen(marker);
    }

    char *status_start = marker_start + strlen(marker);
    if (*status_start == ':')
        status_start++;
    *out_status = atoi(status_start);

    while (marker_start > buffer && (marker_start[-1] == '\n' || marker_start[-1] == '\r'))
        marker_start--;

    size_t output_len = (size_t)(marker_start - buffer);
    char *output = malloc(output_len + 1);
    if (output == NULL)
        return NULL;
    memcpy(output, buffer, output_len);
    output[output_len] = '\0';
    return output;
}

static int read_until_marker(
    struct agentkit_ish_session *session,
    int fd,
    const char *marker,
    int timeout_ms,
    char **out_output,
    int *out_status,
    char **out_error
) {
    int64_t deadline = now_ms() + (timeout_ms > 0 ? timeout_ms : 60000);
    char *buffer = NULL;
    size_t used = 0;
    size_t capacity = 0;

    for (;;) {
        char *output = remove_marker_line(buffer != NULL ? buffer : "", marker, out_status);
        if (output != NULL) {
            free(buffer);
            *out_output = output;
            return 0;
        }

        int64_t remaining = deadline - now_ms();
        if (remaining <= 0) {
            set_error(out_error, "iSH command timed out waiting for %s", marker);
            free(buffer);
            return 124;
        }

        struct pollfd pfd = {.fd = fd, .events = POLLIN};
        int poll_status = poll(&pfd, 1, remaining > 250 ? 250 : (int)remaining);
        if (poll_status < 0) {
            if (errno == EINTR)
                continue;
            set_error(out_error, "poll failed: %s", strerror(errno));
            free(buffer);
            return -1;
        }
        if (poll_status == 0)
            continue;

        char chunk[4096];
        ssize_t count = read(fd, chunk, sizeof(chunk));
        if (count < 0) {
            if (errno == EINTR || errno == EAGAIN)
                continue;
            set_error(out_error, "read failed: %s", strerror(errno));
            free(buffer);
            return -1;
        }
        if (count == 0) {
            int shell_status = -1;
            if (shell_exit_status(session, &shell_status)) {
                if (used > 0) {
                    set_error(out_error, "iSH shell closed before %s (shell status %d, buffered output: %.*s)", marker, shell_status, (int)used, buffer);
                } else {
                    set_error(out_error, "iSH shell closed before %s (shell status %d)", marker, shell_status);
                }
            } else if (used > 0) {
                set_error(out_error, "iSH shell closed before %s (buffered output: %.*s)", marker, (int)used, buffer);
            } else {
                set_error(out_error, "iSH shell closed before %s", marker);
            }
            free(buffer);
            return -1;
        }
        if (append_bytes(&buffer, &used, &capacity, chunk, (size_t)count) < 0) {
            set_error(out_error, "out of memory reading iSH output");
            free(buffer);
            return -1;
        }
    }
}

static void *run_guest_shell(void *context) {
    struct shell_thread_args *args = context;
    struct agentkit_ish_session *session = args->session;
    free(args);

    char *bind_arg = agentkit_strdup_printf("/workspace=%s", session->workspace_path);
    if (bind_arg == NULL)
        return (void *)(intptr_t)ENOMEM;

    char *argv[] = {
        "agentkit-ish-session",
        "-f",
        session->fakefs_path,
        "-b",
        bind_arg,
        "-d",
        "/workspace",
        "/bin/sh",
        NULL,
    };

    agentkit_ish_set_stdio(session->input_read_fd, session->output_write_fd, session->output_write_fd);
    int status = agentkit_ish_run_main(8, argv);
    agentkit_ish_set_stdio(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO);
    record_shell_exit(session, status);
    free(bind_arg);
    return (void *)(intptr_t)status;
}

int agentkit_ish_session_create(
    const char *fakefs_path,
    const char *workspace_path,
    agentkit_ish_session_t **out_session,
    char **out_error
) {
    if (out_session == NULL || fakefs_path == NULL || workspace_path == NULL) {
        set_error(out_error, "missing required iSH session argument");
        return -1;
    }
    *out_session = NULL;

    struct agentkit_ish_session *session = calloc(1, sizeof(*session));
    if (session == NULL) {
        set_error(out_error, "out of memory creating iSH session");
        return -1;
    }

    session->input_read_fd = -1;
    session->input_write_fd = -1;
    session->output_read_fd = -1;
    session->output_write_fd = -1;
    session->shell_status = -1;
    pthread_mutex_init(&session->lock, NULL);
    pthread_mutex_init(&session->lifecycle_lock, NULL);
    session->fakefs_path = strdup(fakefs_path);
    session->workspace_path = strdup(workspace_path);
    if (session->fakefs_path == NULL || session->workspace_path == NULL) {
        set_error(out_error, "out of memory copying iSH session paths");
        agentkit_ish_session_destroy(session);
        return -1;
    }

    int input_pipe[2] = {-1, -1};
    int output_pipe[2] = {-1, -1};
    if (pipe(input_pipe) != 0 || pipe(output_pipe) != 0) {
        set_error(out_error, "pipe failed: %s", strerror(errno));
        if (input_pipe[0] >= 0) close(input_pipe[0]);
        if (input_pipe[1] >= 0) close(input_pipe[1]);
        if (output_pipe[0] >= 0) close(output_pipe[0]);
        if (output_pipe[1] >= 0) close(output_pipe[1]);
        agentkit_ish_session_destroy(session);
        return -1;
    }

    session->input_read_fd = input_pipe[0];
    session->input_write_fd = input_pipe[1];
    session->output_read_fd = output_pipe[0];
    session->output_write_fd = output_pipe[1];

    struct shell_thread_args *args = malloc(sizeof(*args));
    if (args == NULL) {
        set_error(out_error, "out of memory starting iSH thread");
        agentkit_ish_session_destroy(session);
        return -1;
    }
    args->session = session;
    if (pthread_create(&session->thread, NULL, run_guest_shell, args) != 0) {
        set_error(out_error, "pthread_create failed");
        free(args);
        agentkit_ish_session_destroy(session);
        return -1;
    }
    session->started = true;

    char *ready_output = NULL;
    int ready_status = 0;
    int ready = agentkit_ish_session_run(
        session,
        "printf AGENTKIT_ISH_READY",
        10000,
        &ready_output,
        &ready_status,
        out_error
    );
    free(ready_output);
    if (ready != 0 || ready_status != 0) {
        agentkit_ish_session_destroy(session);
        return ready != 0 ? ready : ready_status;
    }

    *out_session = session;
    return 0;
}

int agentkit_ish_session_run(
    agentkit_ish_session_t *session,
    const char *command,
    int timeout_ms,
    char **out_output,
    int *out_status,
    char **out_error
) {
    if (out_output != NULL)
        *out_output = NULL;
    if (out_status != NULL)
        *out_status = -1;
    if (session == NULL || command == NULL) {
        set_error(out_error, "missing iSH command");
        return -1;
    }

    pthread_mutex_lock(&session->lock);
    uint64_t command_id = ++session->next_command_id;
    char marker[128];
    snprintf(marker, sizeof(marker), "__AGENTKIT_ISH_DONE_%llu__", (unsigned long long)command_id);

    char *script = agentkit_strdup_printf(
        "{\n%s\n}\n__agentkit_status=$?\nprintf '\\n%s:%%s\\n' \"$__agentkit_status\"\n",
        command,
        marker
    );
    if (script == NULL) {
        pthread_mutex_unlock(&session->lock);
        set_error(out_error, "out of memory preparing iSH command");
        return -1;
    }

    if (write_all(session->input_write_fd, script) < 0) {
        free(script);
        pthread_mutex_unlock(&session->lock);
        set_error(out_error, "write failed: %s", strerror(errno));
        return -1;
    }
    free(script);

    char *output = NULL;
    int status = -1;
    int result = read_until_marker(
        session,
        session->output_read_fd,
        marker,
        timeout_ms,
        &output,
        &status,
        out_error
    );
    pthread_mutex_unlock(&session->lock);

    if (out_output != NULL)
        *out_output = output;
    else
        free(output);
    if (out_status != NULL)
        *out_status = status;
    return result;
}

void agentkit_ish_session_destroy(agentkit_ish_session_t *session) {
    if (session == NULL)
        return;
    if (!session->closed && session->input_write_fd >= 0) {
        write_all(session->input_write_fd, "exit\n");
        session->closed = true;
    }
    if (session->input_write_fd >= 0) close(session->input_write_fd);
    if (session->started)
        pthread_join(session->thread, NULL);
    if (session->input_read_fd >= 0) close(session->input_read_fd);
    if (session->output_read_fd >= 0) close(session->output_read_fd);
    if (session->output_write_fd >= 0) close(session->output_write_fd);
    pthread_mutex_destroy(&session->lock);
    pthread_mutex_destroy(&session->lifecycle_lock);
    free(session->fakefs_path);
    free(session->workspace_path);
    free(session);
}

void agentkit_ish_free_string(char *value) {
    free(value);
}
