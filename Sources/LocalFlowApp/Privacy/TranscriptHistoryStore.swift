import Foundation
import LocalFlowCore

struct TranscriptHistoryEntry: Equatable, Sendable {
    let identifier: String
    let createdAt: Date
    let language: RecognitionLanguage
    let model: LocalModelChoice
    let text: String
}

actor TranscriptHistoryStore {
    static let maximumRecordCount = 5

    private struct Record: Codable {
        let createdAt: Date
        let language: RecognitionLanguage
        let model: LocalModelChoice
        let text: String
    }

    private struct StoredRecord {
        let url: URL
        let record: Record
    }

    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    func record(
        _ text: String,
        settings: LocalFlowSettings,
        createdAt: Date = Date()
    ) throws {
        guard
            settings.keepTranscriptHistory,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let root = try historyDirectory(createIfNeeded: true)
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: createdAt)
            .replacingOccurrences(of: ":", with: "-")
        let fileURL = root.appendingPathComponent(
            "\(timestamp)-\(UUID().uuidString).json"
        )
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        let record = Record(
            createdAt: createdAt,
            language: settings.language,
            model: settings.model,
            text: text
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: fileURL, options: [.withoutOverwriting])
        try pruneRecords(in: root)
    }

    func entries() throws -> [TranscriptHistoryEntry] {
        let root = try historyDirectory(createIfNeeded: false)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }

        try pruneRecords(in: root)
        return try storedRecords(in: root)
            .prefix(Self.maximumRecordCount)
            .map { stored in
                TranscriptHistoryEntry(
                    identifier: stored.url.lastPathComponent,
                    createdAt: stored.record.createdAt,
                    language: stored.record.language,
                    model: stored.record.model,
                    text: stored.record.text
                )
            }
    }

    func clear() throws {
        let root = try historyDirectory(createIfNeeded: false)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }

        for fileURL in try recordFileURLs(in: root) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private func pruneRecords(in root: URL) throws {
        let records = try storedRecords(in: root)
        guard records.count > Self.maximumRecordCount else { return }

        for stored in records.dropFirst(Self.maximumRecordCount) {
            try FileManager.default.removeItem(at: stored.url)
        }
    }

    private func storedRecords(in root: URL) throws -> [StoredRecord] {
        let records: [StoredRecord] = try recordFileURLs(in: root)
            .compactMap { fileURL -> StoredRecord? in
                guard
                    let data = try? Data(contentsOf: fileURL),
                    let record = Self.decodeRecord(data)
                else {
                    return nil
                }
                return StoredRecord(url: fileURL, record: record)
            }

        return records.sorted { left, right in
            if left.record.createdAt != right.record.createdAt {
                return left.record.createdAt > right.record.createdAt
            }
            return left.url.lastPathComponent > right.url.lastPathComponent
        }
    }

    private static func decodeRecord(_ data: Data) -> Record? {
        let currentDecoder = JSONDecoder()
        currentDecoder.dateDecodingStrategy = .iso8601
        if let record = try? currentDecoder.decode(Record.self, from: data) {
            return record
        }

        // v1.0.5 and earlier used JSONEncoder's default Date representation.
        // Keep those records readable during the capped-history migration.
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func recordFileURLs(in root: URL) throws -> [URL] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey
        ]
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ).filter { url in
            guard url.pathExtension.lowercased() == "json" else {
                return false
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                return false
            }
            return values.isRegularFile == true
                && values.isSymbolicLink != true
        }
    }

    private func historyDirectory(createIfNeeded: Bool) throws -> URL {
        let directory: URL
        if let directoryOverride {
            directory = directoryOverride
        } else {
            guard
                let applicationSupport = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            directory = applicationSupport
                .appendingPathComponent("LocalFlow", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
        }

        if
            createIfNeeded,
            !FileManager.default.fileExists(atPath: directory.path)
        {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }
}
