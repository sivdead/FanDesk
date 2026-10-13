#ifndef FAN_STORAGE_H
#define FAN_STORAGE_H

#include <stdint.h>

// Returns an IOReturn. On success, temperature is the SMART composite
// temperature in Celsius. This function only reads; it changes no disk setting.
int32_t FanStorageReadNVMeTemperature(uint32_t service, double *temperature);

#endif
