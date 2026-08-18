// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "web-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "web-tools-feature", targets: ["web-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../..")
    ],
    targets: [
        .target(
            name: "WebToolsFeature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .executableTarget(
            name: "web-tools-feature",
            dependencies: ["WebToolsFeature"],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "WebToolsFeatureTests",
            dependencies: [
                "WebToolsFeature",
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
