#include "tools/agentkit_ish_runtime.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct session_args {
    const char *fakefs;
};

static void *run_guest_shell(void *context) {
    struct session_args *args = context;
    char *argv[] = {
        "agentkit-ish-session-smoke",
        "-f",
        (char *)args->fakefs,
        "/bin/sh",
        NULL,
    };
    int status = agentkit_ish_run_main(4, argv);
    return (void *)(intptr_t)status;
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

static int read_until_marker(int fd, const char *marker, int log_fd) {
    char buffer[4096];
    size_t used = 0;
    memset(buffer, 0, sizeof(buffer));

    for (;;) {
        if (used + 1 >= sizeof(buffer)) {
            dprintf(log_fd, "buffer filled before marker: %s\n", buffer);
            return -1;
        }
        ssize_t bytes = read(fd, buffer + used, sizeof(buffer) - used - 1);
        if (bytes < 0) {
            if (errno == EINTR)
                continue;
            dprintf(log_fd, "read failed: %s\n", strerror(errno));
            return -1;
        }
        if (bytes == 0) {
            dprintf(log_fd, "guest stdout closed before marker: %s\n", buffer);
            return -1;
        }
        used += (size_t)bytes;
        buffer[used] = '\0';
        if (strstr(buffer, marker) != NULL) {
            dprintf(log_fd, "%s", buffer);
            return 0;
        }
    }
}

static int run_command(int input_fd, int output_fd, int log_fd, const char *command, const char *marker) {
    char script[2048];
    snprintf(
        script,
        sizeof(script),
        "%s\n__agentkit_status=$?\nprintf '\\n%s:%%s\\n' \"$__agentkit_status\"\n",
        command,
        marker
    );
    if (write_all(input_fd, script) < 0) {
        dprintf(log_fd, "write failed: %s\n", strerror(errno));
        return -1;
    }
    return read_until_marker(output_fd, marker, log_fd);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <fakefs>\n", argv[0]);
        return 64;
    }

    int log_fd = dup(STDERR_FILENO);
    int input_pipe[2];
    int output_pipe[2];
    if (pipe(input_pipe) != 0 || pipe(output_pipe) != 0) {
        perror("pipe");
        return 1;
    }

    agentkit_ish_set_stdio(input_pipe[0], output_pipe[1], output_pipe[1]);

    struct session_args args = {.fakefs = argv[1]};
    pthread_t thread;
    if (pthread_create(&thread, NULL, run_guest_shell, &args) != 0) {
        dprintf(log_fd, "pthread_create failed\n");
        return 1;
    }

    int result = 0;
    result |= run_command(
        input_pipe[1],
        output_pipe[0],
        log_fd,
        "cd /workspace && echo session-one > session.txt && cat session.txt",
        "__AGENTKIT_DONE_ONE"
    );
    result |= run_command(
        input_pipe[1],
        output_pipe[0],
        log_fd,
        "cd /workspace && cat session.txt && python3 -c 'print(789)' && rg session .",
        "__AGENTKIT_DONE_TWO"
    );

    write_all(input_pipe[1], "exit\n");
    close(input_pipe[1]);
    pthread_join(thread, NULL);

    agentkit_ish_set_stdio(STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO);
    close(input_pipe[0]);
    close(output_pipe[1]);
    close(output_pipe[0]);
    close(log_fd);

    return result == 0 ? 0 : 1;
}
