// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "figma-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "figma-tools-feature", targets: ["figma-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "figma-tools-feature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE"),
                .product(name: "FeatureMCPBridgeKit", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
