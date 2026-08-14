import Foundation
import LocalFlowCore

actor WhisperRuntimeManager {
    private struct LoadedRuntime: Sendable {
        let choice: LocalModelChoice
        let whisper: WhisperRuntime
        let vad: VoiceActivityRuntime
    }

    private final class LoadFlight: @unchecked Sendable {
        let choice: LocalModelChoice
        let task: Task<LoadedRuntime, Error>

        init(
            choice: LocalModelChoice,
            task: Task<LoadedRuntime, Error>
        ) {
            self.choice = choice
            self.task = task
        }
    }

    private var loaded: LoadedRuntime?
    private var loadFlight: LoadFlight?

    func prepare(_ choice: LocalModelChoice) async throws {
        _ = try await runtime(for: choice)
    }

    func analyzeSpeech(
        _ samples: [Float],
        model: LocalModelChoice
    ) async throws -> VoiceActivityResult {
        let runtime = try await runtime(for: model)
        return try await runtime.vad.analyze(samples)
    }

    func transcribe(
        _ samples: [Float],
        settings: LocalFlowSettings,
        singleSegment: Bool
    ) async throws -> WhisperInferenceResult {
        let runtime = try await runtime(for: settings.model)
        return try await runtime.whisper.transcribe(
            samples: samples,
            language: settings.language,
            initialPrompt: Self.prompt(from: settings.dictionaryEntries),
            singleSegment: singleSegment
        )
    }

    func requestAbort() {
        loaded?.whisper.requestAbort()
    }

    private func runtime(
        for choice: LocalModelChoice
    ) async throws -> LoadedRuntime {
        while true {
            try Task.checkCancellation()
            if let loaded, loaded.choice == choice {
                return loaded
            }

            if let flight = loadFlight {
                do {
                    let result = try await flight.task.value
                    if loadFlight === flight {
                        loaded = result
                        loadFlight = nil
                    }
                    try Task.checkCancellation()
                    if result.choice == choice {
                        return result
                    }
                    continue
                } catch {
                    if loadFlight === flight {
                        loadFlight = nil
                    }
                    if flight.choice == choice {
                        throw error
                    }
                    try Task.checkCancellation()
                    continue
                }
            }

            let task = Task.detached(priority: .userInitiated) {
                let modelURL = try ModelCatalog.locateAndValidate(choice)
                let vadURL = try ModelCatalog.locateVADAndValidate()
                return LoadedRuntime(
                    choice: choice,
                    whisper: try WhisperRuntime(modelURL: modelURL),
                    vad: try VoiceActivityRuntime(modelURL: vadURL)
                )
            }
            loadFlight = LoadFlight(choice: choice, task: task)
        }
    }

    private static func prompt(from entries: [String]) -> String {
        guard !entries.isEmpty else { return "" }
        var prompt = "Словарь: "

        for entry in entries.prefix(80) {
            let candidate = prompt + (prompt.hasSuffix(": ") ? "" : ", ")
                + entry
            guard candidate.utf8.count <= 1_500 else { break }
            prompt = candidate
        }
        return prompt
    }
}
