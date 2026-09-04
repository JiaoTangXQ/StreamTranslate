// NeMo-Speech.cpp exposes an Apache-2.0 C ABI. This bridge loads that ABI at
// runtime so the application can keep the optional NVIDIA runtime and model
// outside the app bundle and fall back to Apple Speech when they are absent.

#include "NemotronBridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t NSStatus;
enum { NSStatusOK = 0 };

typedef struct {
    size_t size;
    int32_t gpu;
} NSBackendConfig;

typedef struct {
    size_t size;
    const char *path;
    const char *name;
} NSModelConfig;

typedef struct {
    size_t size;
    bool enable;
    bool vadBased;
    int32_t stopHistoryEOUMilliseconds;
} NSEndpointingConfig;

typedef struct {
    size_t size;
    const void *backend;
    const void *model;
    const void *streaming;
    const void *decoder;
    const void *vad;
    const void *endpointing;
    const void *postprocessing;
    const void *diarization;
    const void *batching;
} NSRecognizerConfig;

typedef struct {
    size_t size;
    const char *const *phrases;
    size_t phraseCount;
    float boost;
} NSSpeechContext;

typedef struct {
    size_t size;
    const char *requestID;
    const char *languageCode;
    bool interimResults;
    bool enableWordTimeOffsets;
    bool enableAutomaticPunctuation;
    bool verbatimTranscripts;
    bool profanityFilter;
    int32_t stopHistoryEOUMilliseconds;
    const NSSpeechContext *speechContexts;
    size_t speechContextCount;
    int32_t maximumAlternatives;
    bool enableSpeakerDiarization;
    int32_t maximumSpeakerCount;
} NSRecognitionOptions;

typedef NSStatus (*NSCreateFunction)(const NSRecognizerConfig *, void **);
typedef void (*NSDestroyFunction)(void *);
typedef NSRecognitionOptions (*NSDefaultOptionsFunction)(void);
typedef NSStatus (*NSStreamingRecognizeFunction)(
    void *, const NSRecognitionOptions *, void **
);
typedef NSStatus (*NSStreamPushFunction)(
    void *, const float *, size_t, int32_t
);
typedef NSStatus (*NSStreamFinishFunction)(void *);
typedef NSStatus (*NSStreamNextFunction)(void *, void **);
typedef void (*NSStreamCloseFunction)(void *);
typedef bool (*NSResultIsFinalFunction)(const void *);
typedef float (*NSResultAudioProcessedFunction)(const void *);
typedef const char *(*NSResultTranscriptFunction)(const void *, size_t);
typedef void (*NSResultDestroyFunction)(void *);
typedef const char *(*NSLastErrorFunction)(void);

typedef struct {
    NSCreateFunction create;
    NSDestroyFunction destroy;
    NSDefaultOptionsFunction defaultOptions;
    NSStreamingRecognizeFunction streamingRecognize;
    NSStreamPushFunction streamPush;
    NSStreamFinishFunction streamFinish;
    NSStreamNextFunction streamNext;
    NSStreamCloseFunction streamClose;
    NSResultIsFinalFunction resultIsFinal;
    NSResultAudioProcessedFunction resultAudioProcessed;
    NSResultTranscriptFunction resultTranscript;
    NSResultDestroyFunction resultDestroy;
    NSLastErrorFunction lastError;
} NSAPI;

struct STNemotronEngine {
    pthread_mutex_t mutex;
    void *library;
    NSAPI api;
    void *recognizer;
    void *stream;
    char *vocabularyStorage;
    const char **phrases;
    size_t phraseCount;
    NSSpeechContext speechContext;
    NSRecognitionOptions options;
};

static void STSetError(char **output, const char *format, ...) {
    if (!output) return;
    *output = NULL;
    va_list arguments;
    va_start(arguments, format);
    vasprintf(output, format, arguments);
    va_end(arguments);
}

static bool STLoadSymbol(
    void *library,
    const char *name,
    void **destination,
    char **errorMessage
) {
    dlerror();
    *destination = dlsym(library, name);
    const char *error = dlerror();
    if (*destination && !error) return true;
    STSetError(errorMessage, "Missing NeMo-Speech symbol %s: %s", name,
               error ? error : "unknown dynamic-loader error");
    return false;
}

#define ST_LOAD_API(engine, field, symbol)                                      \
    do {                                                                         \
        if (!STLoadSymbol((engine)->library, (symbol),                           \
                          (void **)&((engine)->api.field), errorMessage)) {       \
            goto failed;                                                        \
        }                                                                        \
    } while (0)

static const char *STRuntimeError(STNemotronEngine *engine) {
    const char *message = engine->api.lastError ? engine->api.lastError() : NULL;
    return message && message[0] ? message : "unknown NeMo-Speech runtime error";
}

static void STClearVocabularyLocked(STNemotronEngine *engine) {
    free(engine->phrases);
    free(engine->vocabularyStorage);
    engine->phrases = NULL;
    engine->vocabularyStorage = NULL;
    engine->phraseCount = 0;
    memset(&engine->speechContext, 0, sizeof(engine->speechContext));
}

static void STCloseStreamLocked(STNemotronEngine *engine) {
    if (engine->stream) {
        engine->api.streamClose(engine->stream);
        engine->stream = NULL;
    }
    STClearVocabularyLocked(engine);
}

static void STPrepareVocabularyLocked(
    STNemotronEngine *engine,
    const char *vocabulary
) {
    STClearVocabularyLocked(engine);
    if (!vocabulary || !vocabulary[0]) return;

    engine->vocabularyStorage = strdup(vocabulary);
    if (!engine->vocabularyStorage) return;
    engine->phrases = calloc(100, sizeof(*engine->phrases));
    if (!engine->phrases) {
        STClearVocabularyLocked(engine);
        return;
    }

    char *state = NULL;
    char *candidate = strtok_r(engine->vocabularyStorage, ",\n", &state);
    while (candidate && engine->phraseCount < 100) {
        while (*candidate == ' ' || *candidate == '\t' || *candidate == '\r') {
            ++candidate;
        }
        size_t length = strlen(candidate);
        while (length > 0 && (candidate[length - 1] == ' '
               || candidate[length - 1] == '\t' || candidate[length - 1] == '\r')) {
            candidate[--length] = '\0';
        }
        if (length > 0) engine->phrases[engine->phraseCount++] = candidate;
        candidate = strtok_r(NULL, ",\n", &state);
    }

    if (engine->phraseCount > 0) {
        engine->speechContext.size = sizeof(engine->speechContext);
        engine->speechContext.phrases = engine->phrases;
        engine->speechContext.phraseCount = engine->phraseCount;
        engine->speechContext.boost = 4.0f;
    }
}

static bool STDrainResultsLocked(
    STNemotronEngine *engine,
    STNemotronResultBatch *batch,
    char **errorMessage
) {
    while (true) {
        void *result = NULL;
        NSStatus status = engine->api.streamNext(engine->stream, &result);
        if (status != NSStatusOK) {
            STSetError(errorMessage, "NeMo-Speech result failed (%d): %s",
                       status, STRuntimeError(engine));
            return false;
        }
        if (!result) return true;

        const char *text = engine->api.resultTranscript(result, 0);
        if (text && text[0]) {
            STNemotronResult *items = realloc(
                batch->items, (batch->count + 1) * sizeof(*items)
            );
            if (!items) {
                engine->api.resultDestroy(result);
                STSetError(errorMessage, "Could not allocate a NeMo-Speech result");
                return false;
            }
            batch->items = items;
            STNemotronResult *item = &batch->items[batch->count];
            item->text = strdup(text);
            if (!item->text) {
                engine->api.resultDestroy(result);
                STSetError(errorMessage, "Could not copy a NeMo-Speech result");
                return false;
            }
            item->isFinal = engine->api.resultIsFinal(result);
            item->audioProcessed = engine->api.resultAudioProcessed(result);
            ++batch->count;
        }
        engine->api.resultDestroy(result);
    }
}

STNemotronEngine *STNemotronEngineCreate(
    const char *libraryPath,
    const char *modelPath,
    char **errorMessage
) {
    if (errorMessage) *errorMessage = NULL;
    if (!libraryPath || !modelPath) {
        STSetError(errorMessage, "NeMo-Speech runtime or model path is missing");
        return NULL;
    }

    STNemotronEngine *engine = calloc(1, sizeof(*engine));
    if (!engine) {
        STSetError(errorMessage, "Could not allocate the NeMo-Speech engine");
        return NULL;
    }
    pthread_mutex_init(&engine->mutex, NULL);
    engine->library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
    if (!engine->library) {
        STSetError(errorMessage, "Could not load NeMo-Speech: %s", dlerror());
        goto failed;
    }

    ST_LOAD_API(engine, create, "nemo_speech_asr_create");
    ST_LOAD_API(engine, destroy, "nemo_speech_asr_destroy");
    ST_LOAD_API(engine, defaultOptions,
                "nemo_speech_asr_recognition_options_default");
    ST_LOAD_API(engine, streamingRecognize,
                "nemo_speech_asr_streaming_recognize");
    ST_LOAD_API(engine, streamPush, "nemo_speech_asr_stream_push_f32");
    ST_LOAD_API(engine, streamFinish, "nemo_speech_asr_stream_finish");
    ST_LOAD_API(engine, streamNext, "nemo_speech_asr_stream_next");
    ST_LOAD_API(engine, streamClose, "nemo_speech_asr_stream_close");
    ST_LOAD_API(engine, resultIsFinal, "nemo_speech_asr_result_is_final");
    ST_LOAD_API(engine, resultAudioProcessed,
                "nemo_speech_asr_result_audio_processed");
    ST_LOAD_API(engine, resultTranscript,
                "nemo_speech_asr_result_transcript");
    ST_LOAD_API(engine, resultDestroy, "nemo_speech_asr_result_destroy");
    ST_LOAD_API(engine, lastError, "nemo_speech_asr_last_error");

    NSBackendConfig backend = {
        .size = sizeof(backend),
        .gpu = 0,
    };
    NSModelConfig model = {
        .size = sizeof(model),
        .path = modelPath,
        .name = "nemotron-en",
    };
    NSEndpointingConfig endpointing = {
        .size = sizeof(endpointing),
        .enable = true,
        .vadBased = false,
        .stopHistoryEOUMilliseconds = 1200,
    };
    NSRecognizerConfig config = {
        .size = sizeof(config),
        .backend = &backend,
        .model = &model,
        .endpointing = &endpointing,
    };
    NSStatus status = engine->api.create(&config, &engine->recognizer);
    if (status != NSStatusOK || !engine->recognizer) {
        STSetError(errorMessage, "Could not load Nemotron (%d): %s", status,
                   STRuntimeError(engine));
        goto failed;
    }
    return engine;

failed:
    if (engine->recognizer && engine->api.destroy) {
        engine->api.destroy(engine->recognizer);
    }
    if (engine->library) dlclose(engine->library);
    pthread_mutex_destroy(&engine->mutex);
    free(engine);
    return NULL;
}

bool STNemotronEngineStart(
    STNemotronEngine *engine,
    const char *vocabulary,
    char **errorMessage
) {
    if (errorMessage) *errorMessage = NULL;
    if (!engine) {
        STSetError(errorMessage, "Nemotron engine is unavailable");
        return false;
    }

    pthread_mutex_lock(&engine->mutex);
    STCloseStreamLocked(engine);
    STPrepareVocabularyLocked(engine, vocabulary);
    engine->options = engine->api.defaultOptions();
    engine->options.languageCode = "en-US";
    engine->options.interimResults = true;
    engine->options.enableAutomaticPunctuation = true;
    if (engine->phraseCount > 0) {
        engine->options.speechContexts = &engine->speechContext;
        engine->options.speechContextCount = 1;
    }
    NSStatus status = engine->api.streamingRecognize(
        engine->recognizer, &engine->options, &engine->stream
    );
    if (status != NSStatusOK || !engine->stream) {
        STSetError(errorMessage, "Could not start Nemotron stream (%d): %s",
                   status, STRuntimeError(engine));
        STCloseStreamLocked(engine);
        pthread_mutex_unlock(&engine->mutex);
        return false;
    }
    pthread_mutex_unlock(&engine->mutex);
    return true;
}

bool STNemotronEnginePush(
    STNemotronEngine *engine,
    const float *samples,
    size_t sampleCount,
    int32_t sampleRate,
    STNemotronResultBatch *batch,
    char **errorMessage
) {
    if (errorMessage) *errorMessage = NULL;
    if (batch) memset(batch, 0, sizeof(*batch));
    if (!engine || !samples || sampleCount == 0 || !batch) {
        STSetError(errorMessage, "Invalid Nemotron audio input");
        return false;
    }

    pthread_mutex_lock(&engine->mutex);
    if (!engine->stream) {
        STSetError(errorMessage, "Nemotron stream is not running");
        pthread_mutex_unlock(&engine->mutex);
        return false;
    }
    NSStatus status = engine->api.streamPush(
        engine->stream, samples, sampleCount, sampleRate
    );
    if (status != NSStatusOK) {
        STSetError(errorMessage, "Nemotron audio push failed (%d): %s",
                   status, STRuntimeError(engine));
        pthread_mutex_unlock(&engine->mutex);
        return false;
    }
    bool succeeded = STDrainResultsLocked(engine, batch, errorMessage);
    pthread_mutex_unlock(&engine->mutex);
    if (!succeeded) STNemotronResultBatchFree(batch);
    return succeeded;
}

bool STNemotronEngineFinish(
    STNemotronEngine *engine,
    STNemotronResultBatch *batch,
    char **errorMessage
) {
    if (errorMessage) *errorMessage = NULL;
    if (batch) memset(batch, 0, sizeof(*batch));
    if (!engine || !batch) {
        STSetError(errorMessage, "Nemotron engine is unavailable");
        return false;
    }

    pthread_mutex_lock(&engine->mutex);
    if (!engine->stream) {
        pthread_mutex_unlock(&engine->mutex);
        return true;
    }
    NSStatus status = engine->api.streamFinish(engine->stream);
    if (status != NSStatusOK) {
        STSetError(errorMessage, "Could not finish Nemotron stream (%d): %s",
                   status, STRuntimeError(engine));
        STCloseStreamLocked(engine);
        pthread_mutex_unlock(&engine->mutex);
        return false;
    }
    bool succeeded = STDrainResultsLocked(engine, batch, errorMessage);
    STCloseStreamLocked(engine);
    pthread_mutex_unlock(&engine->mutex);
    if (!succeeded) STNemotronResultBatchFree(batch);
    return succeeded;
}

void STNemotronEngineCancel(STNemotronEngine *engine) {
    if (!engine) return;
    pthread_mutex_lock(&engine->mutex);
    STCloseStreamLocked(engine);
    pthread_mutex_unlock(&engine->mutex);
}

void STNemotronEngineDestroy(STNemotronEngine *engine) {
    if (!engine) return;
    pthread_mutex_lock(&engine->mutex);
    STCloseStreamLocked(engine);
    if (engine->recognizer) {
        engine->api.destroy(engine->recognizer);
        engine->recognizer = NULL;
    }
    void *library = engine->library;
    engine->library = NULL;
    pthread_mutex_unlock(&engine->mutex);
    pthread_mutex_destroy(&engine->mutex);
    if (library) dlclose(library);
    free(engine);
}

void STNemotronResultBatchFree(STNemotronResultBatch *batch) {
    if (!batch) return;
    for (size_t index = 0; index < batch->count; ++index) {
        free(batch->items[index].text);
    }
    free(batch->items);
    batch->items = NULL;
    batch->count = 0;
}

void STNemotronStringFree(char *string) {
    free(string);
}
