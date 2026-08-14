// swift-tools-version: 5.10

import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .path
let whisperVendor = packageRoot + "/Vendor/WhisperCPP-macos13.3"

let package = Package(
    name: "LocalFlow",
    defaultLocalization: "ru",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "LocalFlowCore",
            targets: ["LocalFlowCore"]
        ),
        .executable(
            name: "LocalFlow",
            targets: ["LocalFlowApp"]
        )
    ],
    targets: [
        .target(
            name: "LocalFlowCore"
        ),
        .target(
            name: "CWhisperBridge",
            path: "Sources/CWhisperBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags([
                    "-I\(whisperVendor)/include",
                    "-I\(whisperVendor)/ggml-include"
                ])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(whisperVendor)/lib",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-cpu",
                    "-lggml-blas",
                    "-lggml-metal",
                    "-lggml-base",
                    "-lc++"
                ]),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit")
            ]
        ),
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: ["LocalFlowCore", "CWhisperBridge"],
            linkerSettings: [
                .linkedFramework("Carbon")
            ]
        ),
        .testTarget(
            name: "LocalFlowCoreTests",
            dependencies: ["LocalFlowCore"]
        )
    ],
    swiftLanguageVersions: [.v5],
    cxxLanguageStandard: .cxx17
)
