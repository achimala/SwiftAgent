#pragma once

#ifdef __cplusplus
extern "C" {
#endif

int HermesPython_Initialize(const char *python_home, const char *python_paths, char *error, int error_capacity);
int HermesPython_IsInitialized(void);
char *HermesPython_Evaluate(const char *code, char *error, int error_capacity);
char *HermesPython_RunScript(const char *code, char *error, int error_capacity);

typedef void (*HermesPython_StreamCallback)(const char *event, const char *payload, void *user_context);
typedef char *(*HermesPython_ShellCallback)(
    const char *command,
    const char *cwd,
    int timeout,
    int *status,
    void *user_context
);

void HermesPython_RegisterShellCallback(HermesPython_ShellCallback callback, void *user_context);

char *HermesPython_ConfigureHermes(
    const char *base_url,
    const char *api_key,
    const char *model,
    char *error,
    int error_capacity
);

char *HermesPython_Chat(
    const char *message,
    HermesPython_StreamCallback callback,
    void *user_context,
    char *error,
    int error_capacity
);

void HermesPython_FreeCString(char *value);

#ifdef __cplusplus
}
#endif
