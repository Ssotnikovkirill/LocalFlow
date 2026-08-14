import CWhisperBridge
import Foundation
import LocalFlowCore

struct WhisperInferenceResult: Sendable {
    let text: String
    let detectedLanguage: String
    let averageTokenProbability: Float
    let segmentCount: Int
}

enum WhisperRuntimeError: LocalizedError {
    case modelUnavailable(String)
    case modelLoadFailed(String)
    case audioTooLong
    case inferenceFailed(String)

    var errorDescription: String? {
        switch self {
        case let .modelUnavailable(path):
            return "Локальная модель Whisper не найдена: \(path)"
        case let .modelLoadFailed(reason):
            return "Не удалось загрузить локальную модель: \(reason)"
        case .audioTooLong:
            return "Запись слишком длинная для локального движка"
        case let .inferenceFailed(reason):
            return "Локальное распознавание не выполнено: \(reason)"
        }
    }
}

final class WhisperRuntime: @unchecked Sendable {
    private let handle: OpaquePointer
    private let inferenceQueue = DispatchQueue(
        label: "localflow.whisper.inference",
        qos: .userInitiated
    )
    private let inferenceQueueKey = DispatchSpecificKey<UInt8>()

    init(modelURL: URL) throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw WhisperRuntimeError.modelUnavailable(modelURL.path)
        }

        var errorBuffer = [CChar](repeating: 0, count: 1_024)
        let loadedHandle = modelURL.path.withCString { modelPath in
            lf_whisper_create(
                modelPath,
                &errorBuffer,
                errorBuffer.count
            )
        }
        guard let loadedHandle else {
            throw WhisperRuntimeError.modelLoadFailed(
                String(cString: errorBuffer)
            )
        }
        handle = loadedHandle
        inferenceQueue.setSpecific(
            key: inferenceQueueKey,
            value: 1
        )
    }

    deinit {
        lf_whisper_request_abort(handle)
        let handleToDestroy = handle
        let destroy = {
            lf_whisper_destroy(handleToDestroy)
        }
        if DispatchQueue.getSpecific(key: inferenceQueueKey) != nil {
            destroy()
        } else {
            inferenceQueue.sync(execute: destroy)
        }
    }

    static var engineVersion: String {
        guard let version = lf_whisper_version() else { return "unknown" }
        return String(cString: version)
    }

    func requestAbort() {
        lf_whisper_request_abort(handle)
    }

    func transcribe(
        samples: [Float],
        language: RecognitionLanguage,
        initialPrompt: String,
        singleSegment: Bool
    ) async throws -> WhisperInferenceResult {
        guard samples.count <= Int(Int32.max) else {
            throw WhisperRuntimeError.audioTooLong
        }
        guard !samples.isEmpty else {
            throw WhisperRuntimeError.inferenceFailed("пустая запись")
        }
        let abortGeneration = lf_whisper_abort_generation(handle)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                inferenceQueue.async { [self] in
                    var textBuffer = [CChar](
                        repeating: 0,
                        count: 256 * 1_024
                    )
                    var errorBuffer = [CChar](
                        repeating: 0,
                        count: 1_024
                    )
                    var metadata = LFWhisperResultMetadata()

                    let resultCode = samples.withUnsafeBufferPointer {
                        sampleBuffer in
                        language.whisperCode.withCString { languageCode in
                            initialPrompt.withCString { prompt in
                                lf_whisper_transcribe(
                                    self.handle,
                                    abortGeneration,
                                    sampleBuffer.baseAddress,
                                    Int32(samples.count),
                                    languageCode,
                                    prompt,
                                    4,
                                    singleSegment,
                                    &textBuffer,
                                    textBuffer.count,
                                    &metadata,
                                    &errorBuffer,
                                    errorBuffer.count
                                )
                            }
                        }
                    }

                    guard resultCode == 0 else {
                        if resultCode == 2 {
                            continuation.resume(
                                throwing: CancellationError()
                            )
                        } else {
                            continuation.resume(
                                throwing: WhisperRuntimeError
                                    .inferenceFailed(
                                        String(cString: errorBuffer)
                                    )
                            )
                        }
                        return
                    }

                    let detectedLanguage = withUnsafePointer(
                        to: &metadata.detected_language
                    ) { pointer in
                        pointer.withMemoryRebound(
                            to: CChar.self,
                            capacity: 16
                        ) {
                            String(cString: $0)
                        }
                    }

                    continuation.resume(
                        returning: WhisperInferenceResult(
                            text: String(cString: textBuffer)
                                .trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ),
                            detectedLanguage: detectedLanguage,
                            averageTokenProbability:
                                metadata.average_token_probability,
                            segmentCount: Int(metadata.segment_count)
                        )
                    )
                }
            }
        } onCancel: {
            requestAbort()
        }
    }
}

private extension RecognitionLanguage {
    var whisperCode: String {
        switch self {
        case .russian:
            return "ru"
        case .english:
            return "en"
        case .automatic:
            return "auto"
        }
    }
}
