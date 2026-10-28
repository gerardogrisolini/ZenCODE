// swift-tools-version: 6.4

import PackageDescription

// ZenCRON is the host that cron runs instead of `zen`: macOS attributes the
// privacy permissions of a cron job to it, and to it they stay, so its binary
// must not change from one ZenCODE update to the next. That is why this is a
// standalone package without dependencies, built by `/setup` and replaced on
// macOS only when its host version changes. It deliberately does not depend
// on the ZenCODE package.

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "ZenCRON",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "ZenCRON", targets: ["ZenCRON"])
    ],
    targets: [
        .executableTarget(
            name: "ZenCRON",
            dependencies: [],
            swiftSettings: memberImportVisibilitySettings
        ),
        // Integration tests launch the built ZenCRON executable.
        .testTarget(
            name: "ZenCRONTests",
            dependencies: ["ZenCRON"],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
