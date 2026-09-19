// Powerspaces — GPL-3.0-only
#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef struct { const void *type; uintptr_t state; } PSDockMetadata;
PSDockMetadata PSDockGetMetadata(void *function);
void PSDockMakeConfiguration(void *function, void *result);
void PSDockMakeProvider(void *function, void *result, void *configuration);
void PSDockMakeMaterial(void *function, void *result, void *provider, const void *metadata, const void *witness);
void PSDockSetWindowActive(void *function, void *environment, bool active);
bool PSDockGetWindowActive(void *function, void *environment);
