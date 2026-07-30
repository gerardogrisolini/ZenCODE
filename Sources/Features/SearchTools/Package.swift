// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "search-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "search-tools-feature", targets: ["search-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "search-tools-feature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "LocalToolsSupport", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
