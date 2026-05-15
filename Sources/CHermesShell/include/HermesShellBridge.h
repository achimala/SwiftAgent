#ifndef HERMES_SHELL_BRIDGE_H
#define HERMES_SHELL_BRIDGE_H

#include <stdio.h>

void HermesShell_SetThreadStreams(FILE *input, FILE *output, FILE *error);
void HermesShell_SetPythonInterpreterSlots(int count);

#endif
