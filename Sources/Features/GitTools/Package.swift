// swift-tools-version: 6.4

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "git-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "git-tools-feature", targets: ["git-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(name: "ZenCODE", path: "../../..")
    ],
    targets: [
        .target(
            name: "GitToolsFeature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .executableTarget(
            name: "git-tools-feature",
            dependencies: ["GitToolsFeature"],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "GitToolsFeatureTests",
            dependencies: [
                "GitToolsFeature",
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
