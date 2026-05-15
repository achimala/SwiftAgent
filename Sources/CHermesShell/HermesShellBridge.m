#include "HermesShellBridge.h"

#include <ios_system/ios_system.h>

void HermesShell_SetThreadStreams(FILE *input, FILE *output, FILE *error) {
    thread_stdin = input;
    thread_stdout = output;
    thread_stderr = error;
}

void HermesShell_SetPythonInterpreterSlots(int count) {
    numPythonInterpreters = count;
}
