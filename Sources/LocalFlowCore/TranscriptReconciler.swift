public struct TranscriptPresentation: Equatable, Sendable {
    public let confirmed: String
    public let tentative: String

    public init(confirmed: String, tentative: String) {
        self.confirmed = confirmed
        self.tentative = tentative
    }

    public var combined: String {
        switch (confirmed.isEmpty, tentative.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return tentative
        case (false, true):
            return confirmed
        case (false, false):
            return "\(confirmed) \(tentative)"
        }
    }
}

/// Reconciles overlapping non-causal Whisper hypotheses for display.
///
/// Tokens shared by two consecutive hypotheses are treated as stable, except
/// for a configurable tail. Nothing from this type is inserted into the target
/// application; only the final transcript may be inserted.
public struct TranscriptReconciler: Sendable {
    public let tentativeTailTokenCount: Int
    private var previousTokens: [String] = []
    private var committedTokens: [String] = []

    public init(tentativeTailTokenCount: Int = 1) {
        self.tentativeTailTokenCount = max(0, tentativeTailTokenCount)
    }

    public mutating func update(candidate: String) -> TranscriptPresentation {
        let rawCurrentTokens = Self.tokens(from: candidate)
        let currentTokens = Self.alignedCandidate(
            previous: previousTokens,
            current: rawCurrentTokens,
            committed: committedTokens
        )
        let sharedPrefixCount = Self.commonPrefixCount(
            previousTokens,
            currentTokens
        )
        let newlyConfirmedCount = max(
            0,
            sharedPrefixCount - tentativeTailTokenCount
        )
        let confirmedCount = max(
            min(committedTokens.count, currentTokens.count),
            newlyConfirmedCount
        )

        if confirmedCount > committedTokens.count {
            committedTokens = Array(currentTokens.prefix(confirmedCount))
        }
        let confirmed = committedTokens.joined(separator: " ")
        let tentative = currentTokens.dropFirst(confirmedCount).joined(separator: " ")
        previousTokens = currentTokens

        return TranscriptPresentation(
            confirmed: confirmed,
            tentative: tentative
        )
    }

    public mutating func finalize(text: String) -> TranscriptPresentation {
        let finalText = Self.tokens(from: text).joined(separator: " ")
        previousTokens = []
        committedTokens = []
        return TranscriptPresentation(confirmed: finalText, tentative: "")
    }

    public mutating func reset() {
        previousTokens = []
        committedTokens = []
    }

    private static func tokens(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static func commonPrefixCount(
        _ left: [String],
        _ right: [String]
    ) -> Int {
        var index = 0
        let upperBound = min(left.count, right.count)

        while index < upperBound, left[index] == right[index] {
            index += 1
        }

        return index
    }

    private static func alignedCandidate(
        previous: [String],
        current: [String],
        committed: [String]
    ) -> [String] {
        guard !previous.isEmpty, !current.isEmpty else { return current }

        if commonPrefixCount(previous, current) > 0 {
            return current
        }

        let maximumOverlap = min(previous.count, current.count)
        if maximumOverlap >= 2 {
            for overlap in stride(
                from: maximumOverlap,
                through: 2,
                by: -1
            ) {
                if Array(previous.suffix(overlap))
                    == Array(current.prefix(overlap))
                {
                    return Array(previous.dropLast(overlap)) + current
                }
            }
        }

        if !committed.isEmpty {
            return committed + current
        }
        return current
    }
}
