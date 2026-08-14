import CryptoKit
import Foundation
import LocalFlowCore

struct LocalModelDescriptor: Equatable, Sendable {
    let choice: LocalModelChoice
    let fileName: String
    let expectedByteCount: Int64
    let expectedSHA256: String

    static func descriptor(
        for choice: LocalModelChoice
    ) -> LocalModelDescriptor {
        switch choice {
        case .small:
            return LocalModelDescriptor(
                choice: .small,
                fileName: "ggml-small-q5_1.bin",
                expectedByteCount: 190_085_487,
                expectedSHA256:
                    "52914f6730a59593fd6108d21dcac060a35ce569d9d70eec431e5623f387c82f"
            )
        case .base:
            return LocalModelDescriptor(
                choice: .base,
                fileName: "ggml-base.bin",
                expectedByteCount: 147_951_465,
                expectedSHA256:
                    "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe"
            )
        }
    }
}

enum ModelCatalogError: LocalizedError {
    case notFound(String)
    case wrongSize(expected: Int64, actual: Int64)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case let .notFound(name):
            return "Модель \(name) отсутствует в приложении"
        case let .wrongSize(expected, actual):
            return "Неверный размер модели: ожидалось \(expected), получено \(actual)"
        case .checksumMismatch:
            return "Контрольная сумма локальной модели не совпадает"
        }
    }
}

enum ModelCatalog {
    static func locateAndValidate(
        _ choice: LocalModelChoice
    ) throws -> URL {
        let descriptor = LocalModelDescriptor.descriptor(for: choice)
        guard let url = locate(descriptor) else {
            throw ModelCatalogError.notFound(descriptor.fileName)
        }

        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            throw ModelCatalogError.notFound(descriptor.fileName)
        }

        if descriptor.expectedByteCount > 0 {
            let actualSize = Int64(values.fileSize ?? -1)
            guard actualSize == descriptor.expectedByteCount else {
                throw ModelCatalogError.wrongSize(
                    expected: descriptor.expectedByteCount,
                    actual: actualSize
                )
            }
        }

        if !descriptor.expectedSHA256.isEmpty {
            let actualHash = try sha256(url)
            guard actualHash == descriptor.expectedSHA256 else {
                throw ModelCatalogError.checksumMismatch
            }
        }
        return url
    }

    static func locateVADAndValidate() throws -> URL {
        let fileName = "ggml-silero-v6.2.0.bin"
        let expectedSize: Int64 = 885_098
        let expectedHash =
            "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987"

        let override = ProcessInfo.processInfo
            .environment["LOCALFLOW_VAD_MODEL"]
            .map(URL.init(fileURLWithPath:))
        let bundled = Bundle.main.resourceURL?
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(fileName)
        let url = [override, bundled]
            .compactMap { $0 }
            .first {
                FileManager.default.fileExists(atPath: $0.path)
            }

        guard let url else {
            throw ModelCatalogError.notFound(fileName)
        }
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true else {
            throw ModelCatalogError.notFound(fileName)
        }
        let actualSize = Int64(values.fileSize ?? -1)
        guard actualSize == expectedSize else {
            throw ModelCatalogError.wrongSize(
                expected: expectedSize,
                actual: actualSize
            )
        }
        guard try sha256(url) == expectedHash else {
            throw ModelCatalogError.checksumMismatch
        }
        return url
    }

    private static func locate(
        _ descriptor: LocalModelDescriptor
    ) -> URL? {
        let environmentKey = descriptor.choice == .small
            ? "LOCALFLOW_SMALL_MODEL"
            : "LOCALFLOW_BASE_MODEL"
        if
            let override = ProcessInfo.processInfo.environment[environmentKey],
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }

        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(descriptor.fileName)
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        if
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        {
            let installed = applicationSupport
                .appendingPathComponent("LocalFlow", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(descriptor.fileName)
            if FileManager.default.fileExists(atPath: installed.path) {
                return installed
            }
        }
        return nil
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        var hasher = SHA256()

        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        try handle.close()

        return hasher.finalize().map {
            String(format: "%02x", $0)
        }
        .joined()
    }
}
