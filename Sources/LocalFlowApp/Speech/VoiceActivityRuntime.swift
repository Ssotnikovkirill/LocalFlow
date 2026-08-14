import CWhisperBridge
import Foundation

struct VoiceActivityResult: Sendable {
    let segmentCount: Int
    let firstSpeechStart: TimeInterval
    let lastSpeechEnd: TimeInterval

    var containsSpeech: Bool {
        segmentCount > 0
    }
}

enum VoiceActivityError: LocalizedError {
    case loadFailed(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case let .loadFailed(reason):
            return "Не удалось загрузить локальный VAD: \(reason)"
        case let .analysisFailed(reason):
            return "Проверка наличия речи не выполнена: \(reason)"
        }
    }
}

final class VoiceActivityRuntime: @unchecked Sendable {
    private let handle: OpaquePointer
    private let queue = DispatchQueue(
        label: "localflow.vad.analysis",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()

    init(modelURL: URL) throws {
        var errorBuffer = [CChar](repeating: 0, count: 1_024)
        let loadedHandle = modelURL.path.withCString { modelPath in
            lf_vad_create(modelPath, &errorBuffer, errorBuffer.count)
        }
        guard let loadedHandle else {
            throw VoiceActivityError.loadFailed(
                String(cString: errorBuffer)
            )
        }
        handle = loadedHandle
        queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        let handleToDestroy = handle
        let destroy = {
            lf_vad_destroy(handleToDestroy)
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            destroy()
        } else {
            queue.sync(execute: destroy)
        }
    }

    func analyze(_ samples: [Float]) async throws -> VoiceActivityResult {
        guard !samples.isEmpty, samples.count <= Int(Int32.max) else {
            return VoiceActivityResult(
                segmentCount: 0,
                firstSpeechStart: 0,
                lastSpeechEnd: 0
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                var result = LFVADResult()
                var errorBuffer = [CChar](repeating: 0, count: 1_024)
                let code = samples.withUnsafeBufferPointer { buffer in
                    lf_vad_analyze(
                        self.handle,
                        buffer.baseAddress,
                        Int32(samples.count),
                        &result,
                        &errorBuffer,
                        errorBuffer.count
                    )
                }
                guard code == 0 else {
                    continuation.resume(
                        throwing: VoiceActivityError.analysisFailed(
                            String(cString: errorBuffer)
                        )
                    )
                    return
                }

                continuation.resume(
                    returning: VoiceActivityResult(
                        segmentCount: Int(result.segment_count),
                        firstSpeechStart:
                            TimeInterval(result.first_speech_start),
                        lastSpeechEnd:
                            TimeInterval(result.last_speech_end)
                    )
                )
            }
        }
    }
}
