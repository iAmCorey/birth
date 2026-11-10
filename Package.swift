// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "birth",
    // English is the resource bundles' development region, so systems
    // preferring none of the shipped languages (en, de, zh-Hans) fall back
    // to English. Every language ships as a full semantic-key .strings
    // table; a missing key renders as the raw key, which the key-set
    // completeness test exists to prevent.
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "BirthCore", targets: ["BirthCore"]),
        .executable(name: "Birth", targets: ["Birth"]),
    ],
    targets: [
        .target(
            name: "BirthCore",
            resources: [.process("Resources")]
        ),
        // The whole app lives in a library so its state/policy layer is
        // testable — SPM cannot attach tests to an executable target.
        .target(
            name: "BirthUI",
            dependencies: ["BirthCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Birth",
            dependencies: ["BirthUI"]
        ),
        .testTarget(
            name: "BirthCoreTests",
            dependencies: ["BirthCore"]
        ),
        .testTarget(
            name: "BirthUITests",
            dependencies: ["BirthUI"]
        ),
    ]
)
