#include "LocalFlowWhisperBridge.h"
#include "whisper.h"

#include <algorithm>
#include <atomic>
#include <cstring>
#include <new>
#include <string>

struct LFWhisperHandle {
    whisper_context * context = nullptr;
    std::atomic<uint64_t> abort_generation = 0;
    std::atomic<uint64_t> active_generation = 0;
};

struct LFVADHandle {
    whisper_vad_context * context = nullptr;
};

namespace {

void copy_string(const std::string & source, char * output, size_t capacity) {
    if (output == nullptr || capacity == 0) {
        return;
    }

    const size_t count = std::min(source.size(), capacity - 1);
    std::memcpy(output, source.data(), count);
    output[count] = '\0';
}

bool should_abort(void * user_data) {
    auto * handle = static_cast<LFWhisperHandle *>(user_data);
    return handle != nullptr
        && handle->abort_generation.load(std::memory_order_relaxed)
            != handle->active_generation.load(std::memory_order_relaxed);
}

} // namespace

const char * lf_whisper_version(void) {
    return whisper_version();
}

LFWhisperHandle * lf_whisper_create(
    const char * model_path,
    char * error_output,
    size_t error_capacity
) {
    if (model_path == nullptr || model_path[0] == '\0') {
        copy_string("Model path is empty", error_output, error_capacity);
        return nullptr;
    }

    auto * handle = new (std::nothrow) LFWhisperHandle();
    if (handle == nullptr) {
        copy_string(
            "Unable to allocate Whisper handle",
            error_output,
            error_capacity
        );
        return nullptr;
    }

    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = true;
    params.flash_attn = true;

    handle->context = whisper_init_from_file_with_params(model_path, params);
    if (handle->context == nullptr) {
        copy_string(
            "Unable to load the local Whisper model",
            error_output,
            error_capacity
        );
        delete handle;
        return nullptr;
    }

    if (error_output != nullptr && error_capacity > 0) {
        error_output[0] = '\0';
    }
    return handle;
}

void lf_whisper_destroy(LFWhisperHandle * handle) {
    if (handle == nullptr) {
        return;
    }
    if (handle->context != nullptr) {
        whisper_free(handle->context);
    }
    delete handle;
}

void lf_whisper_request_abort(LFWhisperHandle * handle) {
    if (handle != nullptr) {
        handle->abort_generation.fetch_add(1, std::memory_order_relaxed);
    }
}

uint64_t lf_whisper_abort_generation(LFWhisperHandle * handle) {
    return handle == nullptr
        ? 0
        : handle->abort_generation.load(std::memory_order_relaxed);
}

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
) {
    if (
        handle == nullptr ||
        handle->context == nullptr ||
        samples == nullptr ||
        sample_count <= 0 ||
        text_output == nullptr ||
        text_capacity == 0
    ) {
        copy_string(
            "Invalid transcription arguments",
            error_output,
            error_capacity
        );
        return 1;
    }

    handle->active_generation.store(
        expected_abort_generation,
        std::memory_order_relaxed
    );
    if (
        handle->abort_generation.load(std::memory_order_relaxed)
        != expected_abort_generation
    ) {
        copy_string("Transcription cancelled", error_output, error_capacity);
        return 2;
    }
    text_output[0] = '\0';

    const whisper_sampling_strategy strategy = single_segment
        ? WHISPER_SAMPLING_GREEDY
        : WHISPER_SAMPLING_BEAM_SEARCH;
    whisper_full_params params = whisper_full_default_params(strategy);
    params.n_threads = std::max(1, static_cast<int>(thread_count));
    params.translate = false;
    // Every call is an independent hypothesis/session. Clear history left by
    // the previous call while still allowing whisper_full to carry context
    // between segments within this one call.
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = single_segment;
    params.print_special = false;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = single_segment;
    params.temperature = 0.0f;
    params.temperature_inc = single_segment ? 0.0f : 0.2f;
    params.greedy.best_of = 5;
    params.beam_search.beam_size = 5;
    params.language = language;
    // A null/empty/"auto" language already asks whisper_full to detect the
    // language and continue decoding. `detect_language = true` is a
    // diagnostics-only mode that returns immediately after detection.
    params.detect_language = false;
    params.initial_prompt = (
        initial_prompt != nullptr && initial_prompt[0] != '\0'
    ) ? initial_prompt : nullptr;
    params.abort_callback = should_abort;
    params.abort_callback_user_data = handle;

    const int result = whisper_full(
        handle->context,
        params,
        samples,
        sample_count
    );
    if (result != 0) {
        if (
            handle->abort_generation.load(std::memory_order_relaxed)
            != expected_abort_generation
        ) {
            copy_string(
                "Transcription cancelled",
                error_output,
                error_capacity
            );
            return 2;
        }
        copy_string(
            "Whisper inference failed",
            error_output,
            error_capacity
        );
        return 3;
    }

    std::string transcript;
    double probability_sum = 0.0;
    int64_t probability_count = 0;
    const int segment_count = whisper_full_n_segments(handle->context);

    for (int segment = 0; segment < segment_count; ++segment) {
        const char * segment_text = whisper_full_get_segment_text(
            handle->context,
            segment
        );
        if (segment_text != nullptr) {
            transcript.append(segment_text);
        }

        const int token_count = whisper_full_n_tokens(
            handle->context,
            segment
        );
        for (int token = 0; token < token_count; ++token) {
            probability_sum += whisper_full_get_token_p(
                handle->context,
                segment,
                token
            );
            probability_count += 1;
        }
    }

    if (transcript.size() >= text_capacity) {
        copy_string(
            "Transcript exceeds output capacity",
            error_output,
            error_capacity
        );
        return 4;
    }
    copy_string(transcript, text_output, text_capacity);

    if (metadata != nullptr) {
        metadata->segment_count = segment_count;
        metadata->average_token_probability = probability_count > 0
            ? static_cast<float>(probability_sum / probability_count)
            : 0.0f;
        metadata->detected_language[0] = '\0';

        const int language_id = whisper_full_lang_id(handle->context);
        const char * language_name = whisper_lang_str(language_id);
        if (language_name != nullptr) {
            const size_t capacity = sizeof(metadata->detected_language);
            const size_t count = std::min(
                std::strlen(language_name),
                capacity - 1
            );
            std::memcpy(
                metadata->detected_language,
                language_name,
                count
            );
            metadata->detected_language[count] = '\0';
        }
    }

    if (error_output != nullptr && error_capacity > 0) {
        error_output[0] = '\0';
    }
    return 0;
}

LFVADHandle * lf_vad_create(
    const char * model_path,
    char * error_output,
    size_t error_capacity
) {
    if (model_path == nullptr || model_path[0] == '\0') {
        copy_string("VAD model path is empty", error_output, error_capacity);
        return nullptr;
    }

    auto * handle = new (std::nothrow) LFVADHandle();
    if (handle == nullptr) {
        copy_string(
            "Unable to allocate VAD handle",
            error_output,
            error_capacity
        );
        return nullptr;
    }

    whisper_vad_context_params params =
        whisper_vad_default_context_params();
    params.n_threads = 2;
    params.use_gpu = false;
    handle->context = whisper_vad_init_from_file_with_params(
        model_path,
        params
    );
    if (handle->context == nullptr) {
        copy_string(
            "Unable to load the local VAD model",
            error_output,
            error_capacity
        );
        delete handle;
        return nullptr;
    }

    if (error_output != nullptr && error_capacity > 0) {
        error_output[0] = '\0';
    }
    return handle;
}

void lf_vad_destroy(LFVADHandle * handle) {
    if (handle == nullptr) {
        return;
    }
    if (handle->context != nullptr) {
        whisper_vad_free(handle->context);
    }
    delete handle;
}

int32_t lf_vad_analyze(
    LFVADHandle * handle,
    const float * samples,
    int32_t sample_count,
    LFVADResult * result,
    char * error_output,
    size_t error_capacity
) {
    if (
        handle == nullptr ||
        handle->context == nullptr ||
        samples == nullptr ||
        sample_count <= 0 ||
        result == nullptr
    ) {
        copy_string("Invalid VAD arguments", error_output, error_capacity);
        return 1;
    }

    whisper_vad_params params = whisper_vad_default_params();
    params.speech_pad_ms = 0;
    whisper_vad_segments * segments = whisper_vad_segments_from_samples(
        handle->context,
        params,
        samples,
        sample_count
    );
    if (segments == nullptr) {
        copy_string("VAD analysis failed", error_output, error_capacity);
        return 2;
    }

    const int count = whisper_vad_segments_n_segments(segments);
    result->segment_count = count;
    result->first_speech_start = count > 0
        ? whisper_vad_segments_get_segment_t0(segments, 0)
        : 0.0f;
    result->last_speech_end = count > 0
        ? whisper_vad_segments_get_segment_t1(segments, count - 1)
        : 0.0f;
    whisper_vad_free_segments(segments);

    if (error_output != nullptr && error_capacity > 0) {
        error_output[0] = '\0';
    }
    return 0;
}
