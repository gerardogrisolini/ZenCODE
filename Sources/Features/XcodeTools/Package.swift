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
        .target(
            name: "XcodeToolsFeature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE"),
                .product(name: "FeatureMCPBridgeKit", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .executableTarget(
            name: "xcode-tools-feature",
            dependencies: ["XcodeToolsFeature"],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "XcodeToolsFeatureTests",
            dependencies: [
                "XcodeToolsFeature",
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE"),
                .product(name: "FeatureMCPBridgeKit", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
