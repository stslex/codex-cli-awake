// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "codex-cli-awake",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "CodexAwake", targets: ["CodexAwake"])
    ],
    targets: [
        .executableTarget(
            name: "CodexAwake",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("IOKit")
            ]
        )
    ]
)
