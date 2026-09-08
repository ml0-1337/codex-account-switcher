// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "codex-account-switcher",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodexSwitchCore", targets: ["CodexSwitchCore"]),
        .executable(name: "codex-switch", targets: ["CodexSwitchCLI"]),
    ],
    targets: [
        .target(
            name: "CodexSwitchCore",
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "CodexSwitchCLI",
            dependencies: ["CodexSwitchCore"],
            path: "Sources/codex-switch"
        ),
        .testTarget(name: "CodexSwitchCoreTests", dependencies: ["CodexSwitchCore"]),
    ]
)
