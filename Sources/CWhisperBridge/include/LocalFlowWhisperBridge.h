#ifndef LOCALFLOW_WHISPER_BRIDGE_H
#define LOCALFLOW_WHISPER_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LFWhisperHandle LFWhisperHandle;
typedef struct LFVADHandle LFVADHandle;

typedef struct LFWhisperResultMetadata {
    int32_t segment_count;
    float average_token_probability;
    char detected_language[16];
} LFWhisperResultMetadata;

typedef struct LFVADResult {
    int32_t segment_count;
    float first_speech_start;
    float last_speech_end;
} LFVADResult;

const char * lf_whisper_version(void);

LFWhisperHandle * lf_whisper_create(
    const char * model_path,
    char * error_output,
    size_t error_capacity
);

void lf_whisper_destroy(LFWhisperHandle * handle);

void lf_whisper_request_abort(LFWhisperHandle * handle);

uint64_t lf_whisper_abort_generation(LFWhisperHandle * handle);

int32_t lf_whisper_transcribe(
    LFWhisperHandle * handle,
    uint64_t expected_abort_generation,
    const float * samples,
    int32_t sample_count,
    const char * language,
    const char * initial_prompt,
    int32_t thread_count,
    bool single_segment,
    char * text_output,
    size_t text_capacity,
    LFWhisperResultMetadata * metadata,
    char * error_output,
    size_t error_capacity
);

LFVADHandle * lf_vad_create(
    const char * model_path,
    char * error_output,
    size_t error_capacity
);

void lf_vad_destroy(LFVADHandle * handle);

int32_t lf_vad_analyze(
    LFVADHandle * handle,
    const float * samples,
    int32_t sample_count,
    LFVADResult * result,
    char * error_output,
    size_t error_capacity
);

#ifdef __cplusplus
}
#endif

#endif
