// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "swift-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "swift-tools-feature", targets: ["swift-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "swift-tools-feature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
