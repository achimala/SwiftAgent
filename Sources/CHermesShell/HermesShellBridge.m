#include "HermesShellBridge.h"

#if __has_include(<ios_system/ios_system.h>)
#include <ios_system/ios_system.h>

void HermesShell_SetThreadStreams(FILE *input, FILE *output, FILE *error) {
    thread_stdin = input;
    thread_stdout = output;
    thread_stderr = error;
}

void HermesShell_SetPythonInterpreterSlots(int count) {
    numPythonInterpreters = count;
}
#else
void HermesShell_SetThreadStreams(FILE *input, FILE *output, FILE *error) {
    (void)input;
    (void)output;
    (void)error;
}

void HermesShell_SetPythonInterpreterSlots(int count) {
    (void)count;
}
#endif
