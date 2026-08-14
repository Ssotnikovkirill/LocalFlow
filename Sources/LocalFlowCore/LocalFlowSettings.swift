public enum RecognitionLanguage: String, CaseIterable, Codable, Sendable {
    case russian
    case english
    case automatic

    public var title: String {
        switch self {
        case .russian:
            return "Русский"
        case .english:
            return "English"
        case .automatic:
            return "Auto"
        }
    }
}

public enum LocalModelChoice: String, CaseIterable, Codable, Sendable {
    case small
    case base

    public var title: String {
        switch self {
        case .small:
            return "Whisper small Q5 (точнее)"
        case .base:
            return "Whisper base (быстрее)"
        }
    }
}

public struct LocalFlowSettings: Equatable, Codable, Sendable {
    public var language: RecognitionLanguage
    public var model: LocalModelChoice
    public var launchAtLogin: Bool
    public var showLiveTranscript: Bool
    public var keepTranscriptHistory: Bool
    public var dictionaryEntries: [String]
    public var replacementRules: [TextRule]
    public var snippets: [TextRule]

    public init(
        language: RecognitionLanguage = .russian,
        model: LocalModelChoice = .small,
        launchAtLogin: Bool = false,
        showLiveTranscript: Bool = true,
        keepTranscriptHistory: Bool = false,
        dictionaryEntries: [String] = [],
        replacementRules: [TextRule] = [],
        snippets: [TextRule] = []
    ) {
        self.language = language
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.showLiveTranscript = showLiveTranscript
        self.keepTranscriptHistory = keepTranscriptHistory
        self.dictionaryEntries = dictionaryEntries
        self.replacementRules = replacementRules
        self.snippets = snippets
    }
}
