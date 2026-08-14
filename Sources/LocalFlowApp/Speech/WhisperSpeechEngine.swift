import Foundation
import LocalFlowCore

final class WhisperSpeechEngine: SpeechEngine, @unchecked Sendable {
    private enum SessionStatus: Equatable {
        case recording
        case finalizing
    }

    private struct ActiveSession {
        let id: DictationSessionID
        let settings: LocalFlowSettings
        let timer: DispatchSourceTimer
        let onPartial: @Sendable (String) -> Void
        let onFailure: @Sendable (Error) -> Void
        var status: SessionStatus
        var lastPartialSampleCount: Int
        var partialInFlight: Bool
        var partialTask: Task<Void, Never>?
    }

    private let lock = NSLock()
    private let capture = AudioCaptureEngine()
    private let runtimes = WhisperRuntimeManager()
    private let timerQueue = DispatchQueue(
        label: "localflow.partial.timer",
        qos: .userInitiated
    )
    private var active: ActiveSession?

    func prewarm(settings: LocalFlowSettings) async throws {
        try await runtimes.prepare(settings.model)
    }

    func beginSession(
        id: DictationSessionID,
        settings: LocalFlowSettings,
        onLevel: @escaping @Sendable (Float) -> Void,
        onPartial: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)

        let accepted = withStateLock {
            guard active == nil else { return false }
            active = ActiveSession(
                id: id,
                settings: settings,
                timer: timer,
                onPartial: onPartial,
                onFailure: onFailure,
                status: .recording,
                lastPartialSampleCount: 0,
                partialInFlight: false,
                partialTask: nil
            )
            return true
        }
        guard accepted else {
            throw AudioCaptureError.alreadyRunning
        }

        do {
            try capture.start(
                onLevel: onLevel,
                onError: { [weak self] error in
                    self?.reportCaptureFailure(error, sessionID: id)
                }
            )
        } catch {
            withStateLock {
                if active?.id == id {
                    active = nil
                }
            }
            timer.cancel()
            timer.resume()
            throw error
        }

        timer.setEventHandler { [weak self] in
            self?.startPartialIfNeeded(sessionID: id)
        }
        timer.schedule(
            deadline: .now() + .milliseconds(1_200),
            repeating: .milliseconds(900),
            leeway: .milliseconds(80)
        )
        timer.resume()
    }

    func finishSession(id: DictationSessionID) async throws -> String {
        let preparation = withStateLock {
            () -> (LocalFlowSettings, Task<Void, Never>?)? in
            guard
                var session = active,
                session.id == id,
                session.status == .recording
            else {
                return nil
            }
            session.status = .finalizing
            session.timer.cancel()
            active = session
            return (session.settings, session.partialTask)
        }
        guard let (settings, partialTask) = preparation else {
            throw AppServiceError.missingSession
        }

        partialTask?.cancel()
        await runtimes.requestAbort()
        try Task.checkCancellation()
        guard isFinalizing(id) else {
            throw CancellationError()
        }

        var recording = capture.stop()
        defer {
            recording.zeroize()
            clearSession(id)
        }

        guard !recording.wasTruncated else {
            throw WhisperRuntimeError.audioTooLong
        }
        try Task.checkCancellation()
        guard isFinalizing(id) else {
            throw CancellationError()
        }
        guard recording.duration >= 0.25 else { return "" }

        let voiceActivity = try await runtimes.analyzeSpeech(
            recording.samples,
            model: settings.model
        )
        try Task.checkCancellation()
        guard isFinalizing(id) else {
            throw CancellationError()
        }
        guard voiceActivity.containsSpeech else { return "" }

        let result = try await runtimes.transcribe(
            recording.samples,
            settings: settings,
            singleSegment: false
        )
        try Task.checkCancellation()
        guard isFinalizing(id) else {
            throw CancellationError()
        }
        return TextPostProcessor(
            replacements: settings.replacementRules,
            snippets: settings.snippets
        )
        .process(result.text)
    }

    func cancelSession(id: DictationSessionID) async {
        let cancellation = withStateLock {
            () -> (found: Bool, task: Task<Void, Never>?) in
            guard let session = active, session.id == id else {
                return (false, nil)
            }
            session.timer.cancel()
            active = nil
            return (true, session.partialTask)
        }
        guard cancellation.found else { return }

        cancellation.task?.cancel()
        await runtimes.requestAbort()
        capture.cancelAndZeroize()
    }

    func shutdown() {
        let task = withStateLock { () -> Task<Void, Never>? in
            guard let session = active else { return nil }
            session.timer.cancel()
            active = nil
            return session.partialTask
        }
        task?.cancel()
        capture.cancelAndZeroize()
        Task { [runtimes] in
            await runtimes.requestAbort()
        }
    }

    private func startPartialIfNeeded(sessionID: DictationSessionID) {
        let settings: LocalFlowSettings
        let onPartial: @Sendable (String) -> Void
        let sampleCount = capture.capturedSampleCount()

        lock.lock()
        guard
            var session = active,
            session.id == sessionID,
            session.status == .recording,
            !session.partialInFlight,
            sampleCount >= 16_000,
            sampleCount - session.lastPartialSampleCount >= 9_600
        else {
            lock.unlock()
            return
        }
        session.partialInFlight = true
        session.lastPartialSampleCount = sampleCount
        settings = session.settings
        onPartial = session.onPartial

        let task = Task { [weak self] in
            guard let self else { return }
            var samples = capture.snapshot(lastSeconds: 15)
            defer {
                samples.withUnsafeMutableBytes { bytes in
                    if let baseAddress = bytes.baseAddress {
                        secureZeroMemory(
                            baseAddress,
                            byteCount: bytes.count
                        )
                    }
                }
                samples.removeAll(keepingCapacity: false)
            }

            do {
                try Task.checkCancellation()
                let vad = try await runtimes.analyzeSpeech(
                    samples,
                    model: settings.model
                )
                try Task.checkCancellation()
                guard vad.containsSpeech else {
                    completePartial(sessionID)
                    return
                }

                guard isRecording(sessionID) else {
                    completePartial(sessionID)
                    return
                }
                let result = try await runtimes.transcribe(
                    samples,
                    settings: settings,
                    singleSegment: true
                )
                try Task.checkCancellation()

                if isRecording(sessionID), !result.text.isEmpty {
                    onPartial(result.text)
                }
            } catch is CancellationError {
                // Final decoding superseded this provisional hypothesis.
            } catch {
                if isRecording(sessionID) {
                    reportPartialFailure(error, sessionID: sessionID)
                }
            }
            completePartial(sessionID)
        }
        session.partialTask = task
        active = session
        lock.unlock()
    }

    private func completePartial(_ id: DictationSessionID) {
        lock.lock()
        if var session = active, session.id == id {
            session.partialInFlight = false
            session.partialTask = nil
            active = session
        }
        lock.unlock()
    }

    private func isRecording(_ id: DictationSessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.id == id else { return false }
        return active.status == .recording
    }

    private func isFinalizing(_ id: DictationSessionID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let active, active.id == id else { return false }
        return active.status == .finalizing
    }

    private func reportCaptureFailure(
        _ error: Error,
        sessionID: DictationSessionID
    ) {
        lock.lock()
        let callback = active?.id == sessionID
            ? active?.onFailure
            : nil
        lock.unlock()
        callback?(error)
    }

    private func reportPartialFailure(
        _ error: Error,
        sessionID: DictationSessionID
    ) {
        lock.lock()
        let callback = active?.id == sessionID
            ? active?.onFailure
            : nil
        lock.unlock()
        callback?(error)
    }

    private func clearSession(_ id: DictationSessionID) {
        lock.lock()
        if let active, active.id == id {
            active.timer.cancel()
            self.active = nil
        }
        lock.unlock()
    }

    private func withStateLock<Result>(
        _ operation: () throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }
}
