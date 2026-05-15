#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct agentkit_ish_session agentkit_ish_session_t;

int agentkit_ish_session_create(
    const char *fakefs_path,
    const char *workspace_path,
    agentkit_ish_session_t **out_session,
    char **out_error
);

int agentkit_ish_session_run(
    agentkit_ish_session_t *session,
    const char *command,
    int timeout_ms,
    char **out_output,
    int *out_status,
    char **out_error
);

void agentkit_ish_session_destroy(agentkit_ish_session_t *session);
void agentkit_ish_free_string(char *value);

#ifdef __cplusplus
}
#endif
