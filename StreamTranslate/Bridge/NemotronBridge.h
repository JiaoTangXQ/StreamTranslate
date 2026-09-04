#ifndef STREAMTRANSLATE_NEMOTRON_BRIDGE_H
#define STREAMTRANSLATE_NEMOTRON_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct STNemotronEngine STNemotronEngine;

typedef struct STNemotronResult {
    char *text;
    bool isFinal;
    float audioProcessed;
} STNemotronResult;

typedef struct STNemotronResultBatch {
    STNemotronResult *items;
    size_t count;
} STNemotronResultBatch;

STNemotronEngine *STNemotronEngineCreate(
    const char *libraryPath,
    const char *modelPath,
    char **errorMessage
);

bool STNemotronEngineStart(
    STNemotronEngine *engine,
    const char *vocabulary,
    char **errorMessage
);

bool STNemotronEnginePush(
    STNemotronEngine *engine,
    const float *samples,
    size_t sampleCount,
    int32_t sampleRate,
    STNemotronResultBatch *batch,
    char **errorMessage
);

bool STNemotronEngineFinish(
    STNemotronEngine *engine,
    STNemotronResultBatch *batch,
    char **errorMessage
);

void STNemotronEngineCancel(STNemotronEngine *engine);
void STNemotronEngineDestroy(STNemotronEngine *engine);
void STNemotronResultBatchFree(STNemotronResultBatch *batch);
void STNemotronStringFree(char *string);

#ifdef __cplusplus
}
#endif

#endif
