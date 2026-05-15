#include "tools/agentkit_ish_runtime.h"

#include <unistd.h>

static int agentkit_input_fd = STDIN_FILENO;
static int agentkit_output_fd = STDOUT_FILENO;
static int agentkit_error_fd = STDERR_FILENO;

void agentkit_ish_set_stdio(int input_fd, int output_fd, int error_fd) {
    agentkit_input_fd = input_fd >= 0 ? input_fd : STDIN_FILENO;
    agentkit_output_fd = output_fd >= 0 ? output_fd : STDOUT_FILENO;
    agentkit_error_fd = error_fd >= 0 ? error_fd : STDERR_FILENO;
}

int agentkit_ish_stdin_fd(void) {
    return agentkit_input_fd;
}

int agentkit_ish_stdout_fd(void) {
    return agentkit_output_fd;
}

int agentkit_ish_stderr_fd(void) {
    return agentkit_error_fd;
}
