#pragma once

#ifdef __cplusplus
extern "C" {
#endif

typedef struct swiftagent_ish_session swiftagent_ish_session_t;

int swiftagent_ish_session_create(
    const char *fakefs_path,
    const char *workspace_path,
    swiftagent_ish_session_t **out_session,
    char **out_error
) __asm("_" "agent" "kit_ish_session_create");

int swiftagent_ish_session_run(
    swiftagent_ish_session_t *session,
    const char *command,
    int timeout_ms,
    char **out_output,
    int *out_status,
    char **out_error
) __asm("_" "agent" "kit_ish_session_run");

void swiftagent_ish_session_destroy(swiftagent_ish_session_t *session)
    __asm("_" "agent" "kit_ish_session_destroy");
void swiftagent_ish_free_string(char *value)
    __asm("_" "agent" "kit_ish_free_string");

#ifdef __cplusplus
}
#endif
