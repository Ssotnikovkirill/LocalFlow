import AppKit
import Foundation
import ApplicationServices
import LocalFlowCore

enum DiagnosticsCommand {
    private final class ResultBox: @unchecked Sendable {
        var exitCode = 1
        var output = ""
    }

    private struct CorpusEntry: Sendable {
        let id: String
        let language: RecognitionLanguage
        let languageCode: String
        let pcmURL: URL
        let reference: String
    }

    private struct CorpusSetupTiming: Encodable {
        let validationMilliseconds: Double
        let whisperLoadMilliseconds: Double
        let vadLoadMilliseconds: Double
        let totalMilliseconds: Double
    }

    private struct CorpusSampleResult: Encodable {
        let id: String
        let language: String
        let pcmPath: String
        let audioSeconds: Double
        let readMilliseconds: Double
        let vadMilliseconds: Double
        let inferenceMilliseconds: Double
        let pipelineMilliseconds: Double
        let realTimeFactor: Double
        let vadSegmentCount: Int
        let firstSpeechStartSeconds: Double
        let lastSpeechEndSeconds: Double
        let inferenceSkippedByVAD: Bool
        let whisperSegmentCount: Int
        let detectedLanguage: String
        let averageTokenProbability: Float
        let reference: String
        let transcript: String
        let normalizedReference: String
        let normalizedTranscript: String
        let referenceWordCount: Int
        let wordEditCount: Int
        let wordErrorRate: Double
        let referenceCharacterCount: Int
        let characterEditCount: Int
        let characterErrorRate: Double
        let exactNormalizedMatch: Bool
    }

    private struct CorpusSummary: Encodable {
        let scope: String
        let sampleCount: Int
        let audioSeconds: Double
        let referenceWordCount: Int
        let wordEditCount: Int
        let microWordErrorRate: Double
        let referenceCharacterCount: Int
        let characterEditCount: Int
        let microCharacterErrorRate: Double
        let exactNormalizedCount: Int
        let totalVADMilliseconds: Double
        let totalInferenceMilliseconds: Double
        let totalPipelineMilliseconds: Double
        let aggregateRealTimeFactor: Double
    }

    private struct CorpusBenchmarkReport: Encodable {
        let schemaVersion: Int
        let status: String
        let bundleIdentifier: String
        let bundlePath: String
        let whisperCPPVersion: String
        let model: String
        let modelPath: String
        let vadModelPath: String
        let decoder: String
        let threadCount: Int
        let sampleRateHz: Int
        let setup: CorpusSetupTiming
        let samples: [CorpusSampleResult]
        let summaries: [CorpusSummary]
    }

    private enum CorpusDiagnosticError: LocalizedError {
        case missingManifestArgument
        case requiresPackagedApplication
        case modelOverridePresent(String)
        case bundledResourceMismatch(String)
        case invalidManifest(line: Int, reason: String)
        case emptyManifest
        case invalidPCM(id: String, reason: String)
        case acceptanceFailed(String)
        case unableToEncodeReport

        var errorDescription: String? {
            switch self {
            case .missingManifestArgument:
                return "После --bridge-corpus требуется путь к TSV manifest"
            case .requiresPackagedApplication:
                return "Bridge corpus benchmark должен запускаться из packaged .app"
            case let .modelOverridePresent(key):
                return "Bundled-model test запрещает переменную окружения \(key)"
            case let .bundledResourceMismatch(name):
                return "Модель \(name) загружена не из Contents/Resources/Models"
            case let .invalidManifest(line, reason):
                return "TSV manifest, строка \(line): \(reason)"
            case .emptyManifest:
                return "TSV manifest не содержит образцов"
            case let .invalidPCM(id, reason):
                return "PCM \(id): \(reason)"
            case let .acceptanceFailed(reason):
                return "Строгая проверка корпуса не пройдена: \(reason)"
            case .unableToEncodeReport:
                return "Не удалось сформировать JSON-отчёт"
            }
        }
    }

    @MainActor
    static func runIfRequested() -> Int32? {
        if CommandLine.arguments.contains("--history-store-test") {
            return runHistoryStoreTest()
        }

        if CommandLine.arguments.contains("--settings-ui-test") {
            return runSettingsEditorUITest()
        }

        let strictCorpusIndex = CommandLine.arguments.firstIndex(
            of: "--bridge-corpus-strict"
        )
        let measuredCorpusIndex = CommandLine.arguments.firstIndex(
            of: "--bridge-corpus"
        )
        if let corpusIndex = strictCorpusIndex ?? measuredCorpusIndex {
            let manifestIndex = CommandLine.arguments.index(after: corpusIndex)
            guard manifestIndex < CommandLine.arguments.endIndex else {
                print(
                    "LocalFlow bridge corpus benchmark: FAIL\n"
                        + (
                            CorpusDiagnosticError.missingManifestArgument
                                .errorDescription ?? ""
                        )
                )
                return 2
            }

            let manifestURL = URL(
                fileURLWithPath: CommandLine.arguments[manifestIndex]
            )
            return runCorpusBenchmark(
                manifestURL: manifestURL,
                strict: strictCorpusIndex != nil
            )
        }

        guard CommandLine.arguments.contains("--self-test") else {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()

        Task.detached(priority: .userInitiated) {
            do {
                let smallURL = try ModelCatalog.locateAndValidate(.small)
                let baseURL = try ModelCatalog.locateAndValidate(.base)
                let vadURL = try ModelCatalog.locateVADAndValidate()
                let whisper = try WhisperRuntime(modelURL: smallURL)
                let vad = try VoiceActivityRuntime(modelURL: vadURL)

                let silence = [Float](
                    repeating: 0,
                    count: Int(AudioCaptureEngine.sampleRate * 10)
                )
                let silenceResult = try await vad.analyze(silence)
                guard !silenceResult.containsSpeech else {
                    throw VoiceActivityError.analysisFailed(
                        "тишина ошибочно признана речью"
                    )
                }
                try validateRightOptionFlagDecoder()
                try validateUnobservablePasteTargetPolicy()
                try validateSettingsEditorLayout()
                try await validateTranscriptHistoryStore()

                var lines = [
                    "LocalFlow self-test: PASS",
                    "whisper.cpp: \(WhisperRuntime.engineVersion)",
                    "small model: \(smallURL.lastPathComponent)",
                    "base model: \(baseURL.lastPathComponent)",
                    "VAD silence gate: PASS",
                    "Right Option event decoding: PASS",
                    "Codex unobservable paste policy: PASS",
                    "Settings editor document layout: PASS",
                    "Transcript history retention: PASS"
                ]

                if
                    let nonSpeechPath = ProcessInfo.processInfo
                        .environment[
                            "LOCALFLOW_SELFTEST_NONSPEECH_PCM_F32"
                        ],
                    !nonSpeechPath.isEmpty
                {
                    let nonSpeech = try readFloatPCM(
                        URL(fileURLWithPath: nonSpeechPath)
                    )
                    let nonSpeechResult = try await vad.analyze(nonSpeech)
                    guard !nonSpeechResult.containsSpeech else {
                        throw VoiceActivityError.analysisFailed(
                            "контрольный шум ошибочно признан речью"
                        )
                    }
                    lines.append("VAD noise gate: PASS")
                }

                if
                    let rawPath = ProcessInfo.processInfo
                        .environment["LOCALFLOW_SELFTEST_PCM_F32"],
                    !rawPath.isEmpty
                {
                    let samples = try readFloatPCM(
                        URL(fileURLWithPath: rawPath)
                    )
                    let speech = try await vad.analyze(samples)
                    guard speech.containsSpeech else {
                        throw VoiceActivityError.analysisFailed(
                            "тестовая речь не обнаружена"
                        )
                    }
                    let inference = try await whisper.transcribe(
                        samples: samples,
                        language: .russian,
                        initialPrompt: "",
                        singleSegment: false
                    )
                    guard !inference.text.isEmpty else {
                        throw WhisperRuntimeError.inferenceFailed(
                            "пустой текст на тестовой речи"
                        )
                    }
                    lines.append("speech VAD gate: PASS")
                    lines.append("synthetic transcript: \(inference.text)")

                    let cancellationTask = Task {
                        try await whisper.transcribe(
                            samples: samples + samples + samples,
                            language: .russian,
                            initialPrompt: "",
                            singleSegment: false
                        )
                    }
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    whisper.requestAbort()

                    do {
                        _ = try await cancellationTask.value
                        throw WhisperRuntimeError.inferenceFailed(
                            "отмена inference не сработала"
                        )
                    } catch is CancellationError {
                        lines.append("inference cancellation: PASS")
                    }

                    let recovery = try await whisper.transcribe(
                        samples: samples,
                        language: .russian,
                        initialPrompt: "",
                        singleSegment: false
                    )
                    guard !recovery.text.isEmpty else {
                        throw WhisperRuntimeError.inferenceFailed(
                            "движок не восстановился после отмены"
                        )
                    }
                    lines.append("post-cancellation inference: PASS")

                    let automaticRussian = try await whisper.transcribe(
                        samples: samples,
                        language: .automatic,
                        initialPrompt: "",
                        singleSegment: false
                    )
                    guard
                        !automaticRussian.text.isEmpty,
                        automaticRussian.detectedLanguage.lowercased() == "ru"
                    else {
                        throw WhisperRuntimeError.inferenceFailed(
                            "Auto не распознал русский контрольный образец"
                        )
                    }
                    lines.append("auto RU inference: PASS")

                    if ProcessInfo.processInfo.environment[
                        "LOCALFLOW_SELFTEST_INCLUDE_BASE"
                    ] == "1" {
                        let baseWhisper = try WhisperRuntime(
                            modelURL: baseURL
                        )
                        let baseInference = try await baseWhisper.transcribe(
                            samples: samples,
                            language: .russian,
                            initialPrompt: "",
                            singleSegment: false
                        )
                        guard !baseInference.text.isEmpty else {
                            throw WhisperRuntimeError.inferenceFailed(
                                "base-модель вернула пустой текст"
                            )
                        }
                        lines.append("base inference: PASS")
                        lines.append(
                            "base transcript: \(baseInference.text)"
                        )
                    }
                }

                if
                    let englishPath = ProcessInfo.processInfo.environment[
                        "LOCALFLOW_SELFTEST_AUTO_EN_PCM_F32"
                    ],
                    !englishPath.isEmpty
                {
                    let englishSamples = try readFloatPCM(
                        URL(fileURLWithPath: englishPath)
                    )
                    let englishSpeech = try await vad.analyze(englishSamples)
                    guard englishSpeech.containsSpeech else {
                        throw VoiceActivityError.analysisFailed(
                            "английская тестовая речь не обнаружена"
                        )
                    }
                    let automaticEnglish = try await whisper.transcribe(
                        samples: englishSamples,
                        language: .automatic,
                        initialPrompt: "",
                        singleSegment: false
                    )
                    guard
                        !automaticEnglish.text.isEmpty,
                        automaticEnglish.detectedLanguage.lowercased() == "en"
                    else {
                        throw WhisperRuntimeError.inferenceFailed(
                            "Auto не распознал английский контрольный образец"
                        )
                    }
                    lines.append("auto EN inference: PASS")
                }

                resultBox.exitCode = 0
                resultBox.output = lines.joined(separator: "\n")
            } catch {
                resultBox.exitCode = 1
                resultBox.output = "LocalFlow self-test: FAIL\n"
                    + error.localizedDescription
            }
            semaphore.signal()
        }

        semaphore.wait()
        print(resultBox.output)
        return Int32(resultBox.exitCode)
    }

    @MainActor
    private static func runSettingsEditorUITest() -> Int32 {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let controller = SettingsWindowController(
            settingsStore: SettingsStore(),
            permissionCoordinator: PermissionCoordinator(),
            launchAtLoginController: LaunchAtLoginController()
        )
        let results = controller.runEditorDiagnostics()
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let historyEntries = (1...TranscriptHistoryStore.maximumRecordCount)
            .map { index in
                TranscriptHistoryEntry(
                    identifier: "ui-history-\(index).json",
                    createdAt: baseDate.addingTimeInterval(Double(index)),
                    language: .russian,
                    model: .small,
                    text: "Контрольная транскрипция \(index)"
                )
            }
        let historyResult = controller.runHistoryDiagnostics(
            entries: Array(historyEntries.reversed())
        )

        for result in results {
            print(
                "\(result.name): viewport="
                    + "\(Int(result.viewportSize.width))x"
                    + "\(Int(result.viewportSize.height)), editor="
                    + "\(Int(result.editorSize.width))x"
                    + "\(Int(result.editorSize.height)), pointer="
                    + (result.pointerHitEditor ? "PASS" : "FAIL")
                    + ", typing="
                    + (result.acceptedText ? "PASS" : "FAIL")
            )
        }

        print(
            "История: rows=\(historyResult.rowCount), date-time="
                + (historyResult.timestampContainsDateAndTime ? "PASS" : "FAIL")
                + ", selection-copy="
                + (historyResult.selectionCanBeCopied ? "PASS" : "FAIL")
        )

        guard
            results.count == 3,
            results.allSatisfy(\.passed),
            historyResult.passed
        else {
            print("Settings editor UI test: FAIL")
            return 1
        }
        print("Settings editor UI test: PASS")
        return 0
    }

    @MainActor
    private static func runHistoryStoreTest() -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()

        Task.detached(priority: .userInitiated) {
            do {
                try await validateTranscriptHistoryStore()
                resultBox.exitCode = 0
                resultBox.output =
                    "Transcript history store test: PASS\n"
                    + "maximum records: "
                    + "\(TranscriptHistoryStore.maximumRecordCount)\n"
                    + "timestamps/order/disabled/clear-scope: PASS"
            } catch {
                resultBox.exitCode = 1
                resultBox.output =
                    "Transcript history store test: FAIL\n"
                    + error.localizedDescription
            }
            semaphore.signal()
        }

        semaphore.wait()
        print(resultBox.output)
        return Int32(resultBox.exitCode)
    }

    private static func validateUnobservablePasteTargetPolicy() throws {
        guard
            UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: "com.openai.codex",
                focusedElementWasCaptured: false,
                focusedWindowWasCaptured: true
            ),
            !UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: "com.openai.codex",
                focusedElementWasCaptured: true,
                focusedWindowWasCaptured: true
            ),
            !UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: "com.openai.codex",
                focusedElementWasCaptured: false,
                focusedWindowWasCaptured: false
            ),
            !UnobservablePasteTargetPolicy.permits(
                bundleIdentifier: "com.example.editor",
                focusedElementWasCaptured: false,
                focusedWindowWasCaptured: true
            )
        else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Codex unobservable paste policy"
            )
        }
    }

    private static func validateTranscriptHistoryStore() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "LocalFlow-history-test-\(UUID().uuidString)",
                isDirectory: true
            )
        guard !FileManager.default.fileExists(atPath: root.path) else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history temporary directory collision"
            )
        }
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let store = TranscriptHistoryStore(directoryOverride: root)
        var settings = LocalFlowSettings()
        settings.keepTranscriptHistory = true
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

        for index in 1...7 {
            try await store.record(
                "history-\(index)",
                settings: settings,
                createdAt: baseDate.addingTimeInterval(Double(index))
            )
        }

        let entries = try await store.entries()
        let expectedTexts = (3...7).reversed().map { "history-\($0)" }
        let expectedDates = (3...7).reversed().map {
            baseDate.addingTimeInterval(Double($0))
        }
        guard
            entries.count == TranscriptHistoryStore.maximumRecordCount,
            entries.map(\.text) == expectedTexts,
            entries.map(\.createdAt) == expectedDates
        else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history newest-five retention/order"
            )
        }

        let storedFiles = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "json" }
        guard let migrationSource = storedFiles.first else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history migration fixture"
            )
        }
        try FileManager.default.copyItem(
            at: migrationSource,
            to: root.appendingPathComponent("legacy-extra-a.json")
        )
        try FileManager.default.copyItem(
            at: migrationSource,
            to: root.appendingPathComponent("legacy-extra-b.json")
        )
        let entriesAfterMigration = try await store.entries()
        let filesAfterMigration = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension.lowercased() == "json" }
        guard
            entriesAfterMigration.count
                == TranscriptHistoryStore.maximumRecordCount,
            filesAfterMigration.count
                == TranscriptHistoryStore.maximumRecordCount
        else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history migration pruning"
            )
        }

        settings.keepTranscriptHistory = false
        try await store.record(
            "disabled-history",
            settings: settings,
            createdAt: baseDate.addingTimeInterval(8)
        )
        let entriesAfterOptOut = try await store.entries()
        guard entriesAfterOptOut == entriesAfterMigration else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history opt-out"
            )
        }

        let sentinelURL = root.appendingPathComponent("must-survive.txt")
        try Data("sentinel".utf8).write(
            to: sentinelURL,
            options: [.withoutOverwriting]
        )
        let symlinkURL = root.appendingPathComponent("must-survive-link.json")
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: sentinelURL
        )

        try await store.clear()
        let entriesAfterClear = try await store.entries()
        guard
            entriesAfterClear.isEmpty,
            FileManager.default.fileExists(atPath: sentinelURL.path),
            FileManager.default.fileExists(atPath: symlinkURL.path)
        else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Transcript history clear"
            )
        }
    }

    private static func validateSettingsEditorLayout() throws {
        let initial = SettingsEditorLayout.documentSize(
            current: .zero,
            viewport: NSSize(width: 570, height: 383)
        )
        let grown = SettingsEditorLayout.documentSize(
            current: NSSize(width: 570, height: 640),
            viewport: NSSize(width: 480, height: 383)
        )
        guard
            initial.width == 570,
            initial.height == 383,
            grown.width == 480,
            grown.height == 640
        else {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Settings editor document layout"
            )
        }
    }

    private static func validateRightOptionFlagDecoder() throws {
        let genericPress = CGEventFlags.maskAlternate
        let rightDevicePress = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x00000040
        )
        let leftDeviceOnly = CGEventFlags(
            rawValue: CGEventFlags.maskAlternate.rawValue | 0x00000020
        )

        guard
            RightOptionFlagDecoder.isPressed(flags: genericPress),
            RightOptionFlagDecoder.isPressed(flags: rightDevicePress),
            !RightOptionFlagDecoder.isPressed(flags: leftDeviceOnly),
            !RightOptionFlagDecoder.isPressed(flags: [])
        else {
            throw VoiceActivityError.analysisFailed(
                "декодер Right Option неверно определяет press/release"
            )
        }
    }

    private static func runCorpusBenchmark(
        manifestURL: URL,
        strict: Bool
    ) -> Int32 {
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()

        Task.detached(priority: .userInitiated) {
            do {
                resultBox.output = try await makeCorpusBenchmarkReport(
                    manifestURL: manifestURL,
                    strict: strict
                )
                resultBox.exitCode = 0
            } catch {
                resultBox.exitCode = 1
                resultBox.output =
                    "LocalFlow bridge corpus benchmark: FAIL\n"
                    + error.localizedDescription
            }
            semaphore.signal()
        }

        semaphore.wait()
        print(resultBox.output)
        return Int32(resultBox.exitCode)
    }

    private static func makeCorpusBenchmarkReport(
        manifestURL: URL,
        strict: Bool
    ) async throws -> String {
        try requireBundledModelsOnly()
        let entries = try readCorpusManifest(manifestURL)

        let setupStart = DispatchTime.now().uptimeNanoseconds
        let validationStart = DispatchTime.now().uptimeNanoseconds
        let smallURL = try ModelCatalog.locateAndValidate(.small)
        let vadURL = try ModelCatalog.locateVADAndValidate()
        try requireBundledResource(
            smallURL,
            fileName: "ggml-small-q5_1.bin"
        )
        try requireBundledResource(
            vadURL,
            fileName: "ggml-silero-v6.2.0.bin"
        )
        let validationMilliseconds = elapsedMilliseconds(
            since: validationStart
        )

        let whisperLoadStart = DispatchTime.now().uptimeNanoseconds
        let whisper = try WhisperRuntime(modelURL: smallURL)
        let whisperLoadMilliseconds = elapsedMilliseconds(
            since: whisperLoadStart
        )

        let vadLoadStart = DispatchTime.now().uptimeNanoseconds
        let vad = try VoiceActivityRuntime(modelURL: vadURL)
        let vadLoadMilliseconds = elapsedMilliseconds(since: vadLoadStart)
        let setupTiming = CorpusSetupTiming(
            validationMilliseconds: validationMilliseconds,
            whisperLoadMilliseconds: whisperLoadMilliseconds,
            vadLoadMilliseconds: vadLoadMilliseconds,
            totalMilliseconds: elapsedMilliseconds(since: setupStart)
        )

        var sampleResults: [CorpusSampleResult] = []
        sampleResults.reserveCapacity(entries.count)

        for entry in entries {
            let readStart = DispatchTime.now().uptimeNanoseconds
            let samples = try readFloatPCM(entry.pcmURL)
            guard !samples.isEmpty else {
                throw CorpusDiagnosticError.invalidPCM(
                    id: entry.id,
                    reason: "файл пуст"
                )
            }
            guard samples.allSatisfy(\.isFinite) else {
                throw CorpusDiagnosticError.invalidPCM(
                    id: entry.id,
                    reason: "обнаружены NaN или бесконечные значения"
                )
            }
            let readMilliseconds = elapsedMilliseconds(since: readStart)
            let audioSeconds = Double(samples.count)
                / AudioCaptureEngine.sampleRate

            let pipelineStart = DispatchTime.now().uptimeNanoseconds
            let vadStart = DispatchTime.now().uptimeNanoseconds
            let voiceActivity = try await vad.analyze(samples)
            let vadMilliseconds = elapsedMilliseconds(since: vadStart)

            var transcript = ""
            var detectedLanguage = ""
            var averageTokenProbability: Float = 0
            var whisperSegmentCount = 0
            var inferenceMilliseconds = 0.0

            if voiceActivity.containsSpeech {
                let inferenceStart = DispatchTime.now().uptimeNanoseconds
                let inference = try await whisper.transcribe(
                    samples: samples,
                    language: entry.language,
                    initialPrompt: "",
                    singleSegment: false
                )
                inferenceMilliseconds = elapsedMilliseconds(
                    since: inferenceStart
                )
                transcript = inference.text
                detectedLanguage = inference.detectedLanguage
                averageTokenProbability =
                    inference.averageTokenProbability
                whisperSegmentCount = inference.segmentCount
            }

            let pipelineMilliseconds = elapsedMilliseconds(
                since: pipelineStart
            )
            let normalizedReference = normalizeForMetrics(entry.reference)
            let normalizedTranscript = normalizeForMetrics(transcript)
            let referenceWords = words(normalizedReference)
            let transcriptWords = words(normalizedTranscript)
            let wordEditCount = levenshtein(
                referenceWords,
                transcriptWords
            )
            let referenceCharacters = metricCharacters(
                normalizedReference
            )
            let transcriptCharacters = metricCharacters(
                normalizedTranscript
            )
            let characterEditCount = levenshtein(
                referenceCharacters,
                transcriptCharacters
            )

            sampleResults.append(
                CorpusSampleResult(
                    id: entry.id,
                    language: entry.languageCode,
                    pcmPath: entry.pcmURL.path,
                    audioSeconds: audioSeconds,
                    readMilliseconds: readMilliseconds,
                    vadMilliseconds: vadMilliseconds,
                    inferenceMilliseconds: inferenceMilliseconds,
                    pipelineMilliseconds: pipelineMilliseconds,
                    realTimeFactor:
                        pipelineMilliseconds / 1_000 / audioSeconds,
                    vadSegmentCount: voiceActivity.segmentCount,
                    firstSpeechStartSeconds:
                        voiceActivity.firstSpeechStart,
                    lastSpeechEndSeconds: voiceActivity.lastSpeechEnd,
                    inferenceSkippedByVAD:
                        !voiceActivity.containsSpeech,
                    whisperSegmentCount: whisperSegmentCount,
                    detectedLanguage: detectedLanguage,
                    averageTokenProbability: averageTokenProbability,
                    reference: entry.reference,
                    transcript: transcript,
                    normalizedReference: normalizedReference,
                    normalizedTranscript: normalizedTranscript,
                    referenceWordCount: referenceWords.count,
                    wordEditCount: wordEditCount,
                    wordErrorRate: Double(wordEditCount)
                        / Double(referenceWords.count),
                    referenceCharacterCount: referenceCharacters.count,
                    characterEditCount: characterEditCount,
                    characterErrorRate: Double(characterEditCount)
                        / Double(referenceCharacters.count),
                    exactNormalizedMatch:
                        normalizedReference == normalizedTranscript
                )
            )
        }

        var summaries = [
            summarize(scope: "all", samples: sampleResults)
        ]
        for languageCode in ["ru", "en", "auto"] {
            let matching = sampleResults.filter {
                $0.language == languageCode
            }
            if !matching.isEmpty {
                summaries.append(
                    summarize(scope: languageCode, samples: matching)
                )
            }
        }

        if strict {
            try enforceStrictAcceptance(
                samples: sampleResults,
                summaries: summaries
            )
        }

        let report = CorpusBenchmarkReport(
            schemaVersion: 1,
            status: strict ? "PASS" : "MEASURED",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: Bundle.main.bundleURL.path,
            whisperCPPVersion: WhisperRuntime.engineVersion,
            model: "small-q5_1",
            modelPath: smallURL.path,
            vadModelPath: vadURL.path,
            decoder:
                "beam_search=5; temperature=0; fallback_increment=0.2",
            threadCount: 4,
            sampleRateHz: Int(AudioCaptureEngine.sampleRate),
            setup: setupTiming,
            samples: sampleResults,
            summaries: summaries
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(report)
        guard let output = String(data: data, encoding: .utf8) else {
            throw CorpusDiagnosticError.unableToEncodeReport
        }
        return output
    }

    private static func enforceStrictAcceptance(
        samples: [CorpusSampleResult],
        summaries: [CorpusSummary]
    ) throws {
        if let skipped = samples.first(where: \.inferenceSkippedByVAD) {
            throw CorpusDiagnosticError.acceptanceFailed(
                "VAD пропустил речевой образец \(skipped.id)"
            )
        }
        if let empty = samples.first(where: {
            $0.normalizedTranscript.isEmpty
        }) {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Whisper вернул пустой текст для \(empty.id)"
            )
        }

        let limits: [String: Double] = [
            "all": 0.15,
            "ru": 0.25,
            "en": 0.15,
            "auto": 0.15
        ]
        for summary in summaries {
            guard let limit = limits[summary.scope] else { continue }
            guard summary.microWordErrorRate <= limit else {
                throw CorpusDiagnosticError.acceptanceFailed(
                    "WER \(summary.scope) = "
                        + String(
                            format: "%.4f",
                            locale: Locale(identifier: "en_US_POSIX"),
                            summary.microWordErrorRate
                        )
                        + ", допустимо не более \(limit)"
                )
            }
            guard summary.aggregateRealTimeFactor <= 0.75 else {
                throw CorpusDiagnosticError.acceptanceFailed(
                    "RTF \(summary.scope) = "
                        + String(
                            format: "%.4f",
                            locale: Locale(identifier: "en_US_POSIX"),
                            summary.aggregateRealTimeFactor
                        )
                        + ", допустимо не более 0.75"
                )
            }
        }

        let automaticSamples = samples.filter { $0.language == "auto" }
        if let wrongLanguage = automaticSamples.first(where: {
            !["ru", "en"].contains($0.detectedLanguage.lowercased())
        }) {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Auto не определил ru/en для \(wrongLanguage.id)"
            )
        }
        if let mismatch = automaticSamples.first(where: {
            !$0.exactNormalizedMatch
        }) {
            throw CorpusDiagnosticError.acceptanceFailed(
                "Auto-транскрипт \(mismatch.id) не совпал с эталоном"
            )
        }
    }

    private static func requireBundledModelsOnly() throws {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw CorpusDiagnosticError.requiresPackagedApplication
        }

        let environment = ProcessInfo.processInfo.environment
        for key in [
            "LOCALFLOW_SMALL_MODEL",
            "LOCALFLOW_BASE_MODEL",
            "LOCALFLOW_VAD_MODEL"
        ] where environment[key] != nil {
            throw CorpusDiagnosticError.modelOverridePresent(key)
        }
    }

    private static func requireBundledResource(
        _ actualURL: URL,
        fileName: String
    ) throws {
        guard let resourceURL = Bundle.main.resourceURL else {
            throw CorpusDiagnosticError.requiresPackagedApplication
        }
        let expectedURL = resourceURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(fileName)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedActual = actualURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolvedActual == expectedURL else {
            throw CorpusDiagnosticError.bundledResourceMismatch(fileName)
        }
    }

    private static func readCorpusManifest(
        _ manifestURL: URL
    ) throws -> [CorpusEntry] {
        let content = try String(contentsOf: manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let manifestDirectory = manifestURL
            .standardizedFileURL
            .deletingLastPathComponent()
        var entries: [CorpusEntry] = []
        var identifiers = Set<String>()

        for (offset, rawLine) in content
            .components(separatedBy: "\n")
            .enumerated()
        {
            let lineNumber = offset + 1
            if rawLine.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty {
                continue
            }
            if rawLine.hasPrefix("#") {
                continue
            }

            let columns = rawLine.split(
                separator: "\t",
                maxSplits: 3,
                omittingEmptySubsequences: false
            )
            .map(String.init)

            if
                columns.count == 4,
                columns[0].lowercased() == "id",
                columns[1].lowercased() == "language",
                columns[2].lowercased() == "pcm_f32_path",
                columns[3].lowercased() == "reference"
            {
                continue
            }
            guard columns.count == 4 else {
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason:
                        "ожидаются 4 tab-separated поля: "
                        + "id, language, pcm_f32_path, reference"
                )
            }

            let identifier = columns[0].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !identifier.isEmpty else {
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason: "id пуст"
                )
            }
            guard identifiers.insert(identifier).inserted else {
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason: "id \(identifier) повторяется"
                )
            }

            let languageValue = columns[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let language: RecognitionLanguage
            let languageCode: String
            switch languageValue {
            case "ru", "russian":
                language = .russian
                languageCode = "ru"
            case "en", "english":
                language = .english
                languageCode = "en"
            case "auto", "automatic":
                language = .automatic
                languageCode = "auto"
            default:
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason: "неподдерживаемый language \(columns[1])"
                )
            }

            let rawPath = (columns[2] as NSString)
                .expandingTildeInPath
            guard !rawPath.isEmpty else {
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason: "pcm_f32_path пуст"
                )
            }
            let pcmURL: URL
            if (rawPath as NSString).isAbsolutePath {
                pcmURL = URL(fileURLWithPath: rawPath)
                    .standardizedFileURL
            } else {
                pcmURL = manifestDirectory
                    .appendingPathComponent(rawPath)
                    .standardizedFileURL
            }

            let reference = columns[3].trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalizeForMetrics(reference).isEmpty else {
                throw CorpusDiagnosticError.invalidManifest(
                    line: lineNumber,
                    reason: "reference не содержит букв или цифр"
                )
            }

            entries.append(
                CorpusEntry(
                    id: identifier,
                    language: language,
                    languageCode: languageCode,
                    pcmURL: pcmURL,
                    reference: reference
                )
            )
        }

        guard !entries.isEmpty else {
            throw CorpusDiagnosticError.emptyManifest
        }
        return entries
    }

    private static func normalizeForMetrics(_ text: String) -> String {
        let compatible = text
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        var output = ""
        output.reserveCapacity(compatible.count)

        for scalar in compatible.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
            } else {
                output.append(" ")
            }
        }
        return output.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func words(_ normalized: String) -> [String] {
        normalized.split(separator: " ").map(String.init)
    }

    private static func metricCharacters(
        _ normalized: String
    ) -> [String] {
        normalized.unicodeScalars.compactMap { scalar in
            CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? nil
                : String(scalar)
        }
    }

    private static func levenshtein<Element: Equatable>(
        _ reference: [Element],
        _ hypothesis: [Element]
    ) -> Int {
        if reference.isEmpty { return hypothesis.count }
        if hypothesis.isEmpty { return reference.count }

        var previous = Array(0...hypothesis.count)
        for (referenceIndex, referenceElement) in reference.enumerated() {
            var current = [referenceIndex + 1]
            current.reserveCapacity(hypothesis.count + 1)

            for (hypothesisIndex, hypothesisElement) in
                hypothesis.enumerated()
            {
                let insertion = current[hypothesisIndex] + 1
                let deletion = previous[hypothesisIndex + 1] + 1
                let substitution = previous[hypothesisIndex]
                    + (referenceElement == hypothesisElement ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[hypothesis.count]
    }

    private static func summarize(
        scope: String,
        samples: [CorpusSampleResult]
    ) -> CorpusSummary {
        let audioSeconds = samples.reduce(0) {
            $0 + $1.audioSeconds
        }
        let referenceWordCount = samples.reduce(0) {
            $0 + $1.referenceWordCount
        }
        let wordEditCount = samples.reduce(0) {
            $0 + $1.wordEditCount
        }
        let referenceCharacterCount = samples.reduce(0) {
            $0 + $1.referenceCharacterCount
        }
        let characterEditCount = samples.reduce(0) {
            $0 + $1.characterEditCount
        }
        let totalVADMilliseconds = samples.reduce(0) {
            $0 + $1.vadMilliseconds
        }
        let totalInferenceMilliseconds = samples.reduce(0) {
            $0 + $1.inferenceMilliseconds
        }
        let totalPipelineMilliseconds = samples.reduce(0) {
            $0 + $1.pipelineMilliseconds
        }

        return CorpusSummary(
            scope: scope,
            sampleCount: samples.count,
            audioSeconds: audioSeconds,
            referenceWordCount: referenceWordCount,
            wordEditCount: wordEditCount,
            microWordErrorRate:
                Double(wordEditCount) / Double(referenceWordCount),
            referenceCharacterCount: referenceCharacterCount,
            characterEditCount: characterEditCount,
            microCharacterErrorRate:
                Double(characterEditCount)
                / Double(referenceCharacterCount),
            exactNormalizedCount: samples.filter(
                \.exactNormalizedMatch
            ).count,
            totalVADMilliseconds: totalVADMilliseconds,
            totalInferenceMilliseconds: totalInferenceMilliseconds,
            totalPipelineMilliseconds: totalPipelineMilliseconds,
            aggregateRealTimeFactor:
                totalPipelineMilliseconds / 1_000 / audioSeconds
        )
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func readFloatPCM(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
}
