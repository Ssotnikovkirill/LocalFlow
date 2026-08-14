import Foundation
import LocalFlowCore

@MainActor
final class SettingsStore {
    private enum Key {
        static let language = "recognitionLanguage"
        static let model = "localModel"
        static let launchAtLogin = "launchAtLogin"
        static let showLiveTranscript = "showLiveTranscript"
        static let keepTranscriptHistory = "keepTranscriptHistory"
        static let dictionaryEntries = "dictionaryEntries"
        static let replacementRules = "replacementRules"
        static let snippets = "snippets"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.language: RecognitionLanguage.russian.rawValue,
            Key.model: LocalModelChoice.small.rawValue,
            Key.launchAtLogin: false,
            Key.showLiveTranscript: true,
            Key.keepTranscriptHistory: false
        ])
    }

    var settings: LocalFlowSettings {
        get {
            LocalFlowSettings(
                language: RecognitionLanguage(
                    rawValue: defaults.string(forKey: Key.language) ?? ""
                ) ?? .russian,
                model: LocalModelChoice(
                    rawValue: defaults.string(forKey: Key.model) ?? ""
                ) ?? .small,
                launchAtLogin: defaults.bool(forKey: Key.launchAtLogin),
                showLiveTranscript: defaults.bool(
                    forKey: Key.showLiveTranscript
                ),
                keepTranscriptHistory: defaults.bool(
                    forKey: Key.keepTranscriptHistory
                ),
                dictionaryEntries: decode(
                    [String].self,
                    forKey: Key.dictionaryEntries
                ) ?? [],
                replacementRules: decode(
                    [TextRule].self,
                    forKey: Key.replacementRules
                ) ?? [],
                snippets: decode(
                    [TextRule].self,
                    forKey: Key.snippets
                ) ?? []
            )
        }
        set {
            defaults.set(newValue.language.rawValue, forKey: Key.language)
            defaults.set(newValue.model.rawValue, forKey: Key.model)
            defaults.set(newValue.launchAtLogin, forKey: Key.launchAtLogin)
            defaults.set(
                newValue.showLiveTranscript,
                forKey: Key.showLiveTranscript
            )
            defaults.set(
                newValue.keepTranscriptHistory,
                forKey: Key.keepTranscriptHistory
            )
            encode(
                newValue.dictionaryEntries,
                forKey: Key.dictionaryEntries
            )
            encode(
                newValue.replacementRules,
                forKey: Key.replacementRules
            )
            encode(newValue.snippets, forKey: Key.snippets)
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        forKey key: String
    ) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func encode<Value: Encodable>(
        _ value: Value,
        forKey key: String
    ) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
