#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int agentkit_ish_run_main(int argc, char *const argv[]);
void agentkit_ish_set_stdio(int input_fd, int output_fd, int error_fd);
int agentkit_ish_stdin_fd(void);
int agentkit_ish_stdout_fd(void);
int agentkit_ish_stderr_fd(void);

#ifdef __cplusplus
}
#endif
