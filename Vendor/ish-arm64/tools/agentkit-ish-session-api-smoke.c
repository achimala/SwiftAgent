#include "tools/agentkit_ish_session.h"

#include <stdio.h>
#include <stdlib.h>

static int run(agentkit_ish_session_t *session, const char *command) {
    char *output = NULL;
    char *error = NULL;
    int status = -1;
    int result = agentkit_ish_session_run(session, command, 30000, &output, &status, &error);
    if (result != 0) {
        fprintf(stderr, "run failed: %s\n", error ? error : "(no error)");
        agentkit_ish_free_string(error);
        agentkit_ish_free_string(output);
        return result;
    }
    printf("$ %s\n%s[status %d]\n\n", command, output ? output : "", status);
    agentkit_ish_free_string(output);
    return status;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <fakefs> <workspace>\n", argv[0]);
        return 64;
    }

    agentkit_ish_session_t *session = NULL;
    char *error = NULL;
    int result = agentkit_ish_session_create(argv[1], argv[2], &session, &error);
    if (result != 0) {
        fprintf(stderr, "create failed: %s\n", error ? error : "(no error)");
        agentkit_ish_free_string(error);
        return result;
    }

    result |= run(session, "pwd");
    result |= run(session, "echo api-session-one > session.txt && cat session.txt");
    result |= run(session, "cat session.txt && python3 -c 'print(321)' && rg api-session .");
    result |= run(session, "cat /workspace/session.txt");

    agentkit_ish_session_destroy(session);
    return result == 0 ? 0 : 1;
}
