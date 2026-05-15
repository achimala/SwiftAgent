#include "tools/agentkit_ish_runtime.h"

#include <stdio.h>

int main(int argc, char *const argv[]) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s <fakefs> <command-one> <command-two>\n", argv[0]);
        return 64;
    }

    char *first[] = {
        argv[0],
        "-f",
        argv[1],
        "/bin/sh",
        "-c",
        argv[2],
        NULL,
    };
    int first_status = agentkit_ish_run_main(6, first);
    printf("first_status=%d\n", first_status);

    char *second[] = {
        argv[0],
        "-f",
        argv[1],
        "/bin/sh",
        "-c",
        argv[3],
        NULL,
    };
    int second_status = agentkit_ish_run_main(6, second);
    printf("second_status=%d\n", second_status);

    return first_status == 0 ? second_status : first_status;
}
