public struct DictationSessionUpdate: Equatable, Sendable {
    public let state: DictationState
    public let transcript: TranscriptPresentation
    public let commands: [ActivationCommand]

    public init(
        state: DictationState,
        transcript: TranscriptPresentation,
        commands: [ActivationCommand]
    ) {
        self.state = state
        self.transcript = transcript
        self.commands = commands
    }
}

/// Serializes all asynchronous callbacks for one dictation lifecycle.
///
/// Audio callbacks should enqueue data into their own realtime-safe buffer and
/// call this actor only from a non-realtime task.
public actor DictationSession {
    private var stateMachine = ActivationStateMachine()
    private var reconciler: TranscriptReconciler
    private var transcript = TranscriptPresentation(confirmed: "", tentative: "")
    private var nextSessionValue: UInt64 = 1

    public init(tentativeTailTokenCount: Int = 1) {
        reconciler = TranscriptReconciler(
            tentativeTailTokenCount: tentativeTailTokenCount
        )
    }

    public func rightOptionPressed() -> DictationSessionUpdate {
        guard stateMachine.state == .idle else {
            return currentUpdate()
        }

        reconciler.reset()
        transcript = TranscriptPresentation(confirmed: "", tentative: "")
        let id = DictationSessionID(rawValue: nextSessionValue)
        nextSessionValue &+= 1
        let commands = stateMachine.handle(.rightOptionPressed(id))
        return currentUpdate(commands: commands)
    }

    public func rightOptionReleased() -> DictationSessionUpdate {
        guard let id = stateMachine.state.sessionID else {
            return currentUpdate()
        }

        let commands = stateMachine.handle(.rightOptionReleased(id))
        return currentUpdate(commands: commands)
    }

    public func acceptPartial(
        _ candidate: String,
        for id: DictationSessionID
    ) -> DictationSessionUpdate {
        guard stateMachine.state.sessionID == id else {
            return currentUpdate()
        }

        switch stateMachine.state {
        case .recording, .finalizing:
            transcript = reconciler.update(candidate: candidate)
        case .idle, .inserting:
            break
        }

        return currentUpdate()
    }

    public func completeTranscription(
        _ finalText: String,
        for id: DictationSessionID
    ) -> DictationSessionUpdate {
        guard stateMachine.state == .finalizing(id) else {
            return currentUpdate()
        }

        transcript = reconciler.finalize(text: finalText)
        let commands = stateMachine.handle(
            .transcriptionCompleted(id, text: finalText)
        )
        return currentUpdate(commands: commands)
    }

    public func completeInsertion(
        for id: DictationSessionID
    ) -> DictationSessionUpdate {
        let commands = stateMachine.handle(.insertionCompleted(id))
        return currentUpdate(commands: commands)
    }

    public func fail(
        sessionID: DictationSessionID,
        message: String
    ) -> DictationSessionUpdate {
        let commands = stateMachine.handle(
            .failure(sessionID, message: message)
        )
        return currentUpdate(commands: commands)
    }

    public func cancel() -> DictationSessionUpdate {
        let commands = stateMachine.handle(
            .cancel(stateMachine.state.sessionID)
        )
        reconciler.reset()
        transcript = TranscriptPresentation(confirmed: "", tentative: "")
        return currentUpdate(commands: commands)
    }

    public func snapshot() -> DictationSessionUpdate {
        currentUpdate()
    }

    private func currentUpdate(
        commands: [ActivationCommand] = []
    ) -> DictationSessionUpdate {
        DictationSessionUpdate(
            state: stateMachine.state,
            transcript: transcript,
            commands: commands
        )
    }
}
