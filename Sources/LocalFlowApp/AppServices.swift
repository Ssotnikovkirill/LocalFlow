import Foundation
import LocalFlowCore

enum AppServiceError: LocalizedError {
    case missingSession

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "Активная сессия диктовки не найдена"
        }
    }
}

protocol SpeechEngine: AnyObject, Sendable {
    func prewarm(settings: LocalFlowSettings) async throws
    func beginSession(
        id: DictationSessionID,
        settings: LocalFlowSettings,
        onLevel: @escaping @Sendable (Float) -> Void,
        onPartial: @escaping @Sendable (String) -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async throws
    func finishSession(id: DictationSessionID) async throws -> String
    func cancelSession(id: DictationSessionID) async
    func shutdown()
}

enum TextInsertionOutcome: Equatable, Sendable {
    case accessibility
    case pasteboard
    case unobservablePaste
    case unicodeEvents
    case copied
}

protocol TextInsertionService: AnyObject, Sendable {
    func captureTarget(for id: DictationSessionID) async throws
    func insert(
        _ text: String,
        for id: DictationSessionID
    ) async throws -> TextInsertionOutcome
    func discardTarget(for id: DictationSessionID) async
}
