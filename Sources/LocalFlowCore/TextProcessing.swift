import Foundation

public struct TextRule: Codable, Equatable, Hashable, Sendable {
    public var trigger: String
    public var replacement: String

    public init(trigger: String, replacement: String) {
        self.trigger = trigger
        self.replacement = replacement
    }
}

public enum TextRuleCodec {
    public struct ParseIssue: Equatable, Sendable {
        public let line: Int
        public let message: String

        public init(line: Int, message: String) {
            self.line = line
            self.message = message
        }
    }

    public struct ParseResult: Equatable, Sendable {
        public let rules: [TextRule]
        public let issues: [ParseIssue]

        public init(rules: [TextRule], issues: [ParseIssue]) {
            self.rules = rules
            self.issues = issues
        }
    }

    /// Parses one `trigger => replacement` rule per line.
    ///
    /// Empty lines and lines beginning with `#` are ignored. In replacements,
    /// `\n` and `\t` become a newline and a tab. A literal backslash is
    /// represented as `\\`.
    public static func parse(_ source: String) -> ParseResult {
        var rules: [TextRule] = []
        var issues: [ParseIssue] = []
        var seenTriggers = Set<String>()

        for (offset, rawLine) in source.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            guard let delimiter = line.range(of: "=>") else {
                issues.append(
                    ParseIssue(
                        line: lineNumber,
                        message: "ожидается разделитель =>"
                    )
                )
                continue
            }

            let trigger = line[..<delimiter.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            let encodedReplacement = line[delimiter.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            let replacement = decodeEscapes(String(encodedReplacement))

            guard !trigger.isEmpty else {
                issues.append(
                    ParseIssue(
                        line: lineNumber,
                        message: "пустой триггер"
                    )
                )
                continue
            }

            let normalizedTrigger = trigger.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "ru_RU")
            )
            guard seenTriggers.insert(normalizedTrigger).inserted else {
                issues.append(
                    ParseIssue(
                        line: lineNumber,
                        message: "повторяющийся триггер"
                    )
                )
                continue
            }

            rules.append(
                TextRule(
                    trigger: trigger,
                    replacement: replacement
                )
            )
        }

        return ParseResult(rules: rules, issues: issues)
    }

    public static func encode(_ rules: [TextRule]) -> String {
        rules.map {
            "\($0.trigger) => \(encodeEscapes($0.replacement))"
        }
        .joined(separator: "\n")
    }

    private static func decodeEscapes(_ source: String) -> String {
        var result = ""
        var isEscaping = false

        for character in source {
            if isEscaping {
                switch character {
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "\\":
                    result.append("\\")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaping = false
            } else if character == "\\" {
                isEscaping = true
            } else {
                result.append(character)
            }
        }

        if isEscaping {
            result.append("\\")
        }
        return result
    }

    private static func encodeEscapes(_ source: String) -> String {
        source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
    }
}

public struct TextPostProcessor: Sendable {
    public var replacements: [TextRule]
    public var snippets: [TextRule]

    public init(
        replacements: [TextRule] = [],
        snippets: [TextRule] = []
    ) {
        self.replacements = replacements
        self.snippets = snippets
    }

    public func process(_ transcript: String) -> String {
        var result = Self.normalizeSpacing(transcript)
        result = Self.apply(replacements, to: result)
        result = Self.apply(snippets, to: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeSpacing(_ source: String) -> String {
        var result = source
            .replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([,.;:!?])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([\(\[\{«])\s+"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+([\)\]\}»])"#,
                with: "$1",
                options: .regularExpression
            )

        result = result.replacingOccurrences(
            of: #"\n[ \t]+"#,
            with: "\n",
            options: .regularExpression
        )
        return result
    }

    private static func apply(
        _ rules: [TextRule],
        to source: String
    ) -> String {
        let orderedRules = rules.sorted {
            $0.trigger.count > $1.trigger.count
        }

        return orderedRules.reduce(source) { partial, rule in
            guard !rule.trigger.isEmpty else { return partial }

            let escaped = NSRegularExpression.escapedPattern(
                for: rule.trigger
            )
            let pattern =
                #"(?<![\p{L}\p{N}_])"# +
                escaped +
                #"(?![\p{L}\p{N}_])"#

            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                return partial
            }

            let range = NSRange(
                partial.startIndex..<partial.endIndex,
                in: partial
            )
            let template = NSRegularExpression.escapedTemplate(
                for: rule.replacement
            )
            return expression.stringByReplacingMatches(
                in: partial,
                range: range,
                withTemplate: template
            )
        }
    }
}
