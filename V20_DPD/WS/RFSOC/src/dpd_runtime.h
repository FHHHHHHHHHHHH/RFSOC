#ifndef ZCU111_V20_DPD_RUNTIME_H
#define ZCU111_V20_DPD_RUNTIME_H

int DpdProcessCommand(const char *command, const char *argument);
void DpdPrintHelp(void);
void DpdRuntimePrintVersions(void);

#endif
