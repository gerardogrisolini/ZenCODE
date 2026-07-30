// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "xcode-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "xcode-tools-feature", targets: ["xcode-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "xcode-tools-feature",
            dependencies: [
                .product(name: "XcodeToolsFeature", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
