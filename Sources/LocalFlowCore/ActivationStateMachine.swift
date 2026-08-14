public struct DictationSessionID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording(DictationSessionID)
    case finalizing(DictationSessionID)
    case inserting(DictationSessionID)

    public var sessionID: DictationSessionID? {
        switch self {
        case .idle:
            return nil
        case let .recording(id), let .finalizing(id), let .inserting(id):
            return id
        }
    }
}

public enum ActivationEvent: Equatable, Sendable {
    case rightOptionPressed(DictationSessionID)
    case rightOptionReleased(DictationSessionID)
    case transcriptionCompleted(DictationSessionID, text: String)
    case insertionCompleted(DictationSessionID)
    case cancel(DictationSessionID?)
    case failure(DictationSessionID, message: String)
}

public enum ActivationCommand: Equatable, Sendable {
    case showOverlay
    case beginCapture(DictationSessionID)
    case stopCaptureAndTranscribe(DictationSessionID)
    case showFinalizing
    case showFinalText(String)
    case insertText(DictationSessionID, text: String)
    case abortCapture(DictationSessionID)
    case presentError(String)
    case hideOverlay
}

public struct ActivationStateMachine: Sendable {
    public private(set) var state: DictationState

    public init(initialState: DictationState = .idle) {
        state = initialState
    }

    @discardableResult
    public mutating func handle(_ event: ActivationEvent) -> [ActivationCommand] {
        switch (state, event) {
        case let (.idle, .rightOptionPressed(id)):
            state = .recording(id)
            return [.showOverlay, .beginCapture(id)]

        case let (.recording(activeID), .rightOptionReleased(eventID))
            where activeID == eventID:
            state = .finalizing(activeID)
            return [
                .showFinalizing,
                .stopCaptureAndTranscribe(activeID)
            ]

        case let (.finalizing(activeID), .transcriptionCompleted(eventID, text))
            where activeID == eventID:
            let normalizedText = Self.trimmed(text)
            guard !normalizedText.isEmpty else {
                state = .idle
                return [.hideOverlay]
            }

            state = .inserting(activeID)
            return [
                .showFinalText(normalizedText),
                .insertText(activeID, text: normalizedText)
            ]

        case let (.inserting(activeID), .insertionCompleted(eventID))
            where activeID == eventID:
            state = .idle
            return [.hideOverlay]

        case let (activeState, .cancel(requestedID)):
            guard
                let activeID = activeState.sessionID,
                requestedID == nil || requestedID == activeID
            else {
                return []
            }

            state = .idle
            return [.abortCapture(activeID), .hideOverlay]

        case let (activeState, .failure(eventID, message))
            where activeState.sessionID == eventID:
            state = .idle
            return [
                .abortCapture(eventID),
                .presentError(message),
                .hideOverlay
            ]

        default:
            // Repeats, stale callbacks, and out-of-order completions are ignored.
            return []
        }
    }

    private static func trimmed(_ text: String) -> String {
        guard
            let first = text.firstIndex(where: { !$0.isWhitespace }),
            let last = text.lastIndex(where: { !$0.isWhitespace })
        else {
            return ""
        }

        return String(text[first...last])
    }
}
