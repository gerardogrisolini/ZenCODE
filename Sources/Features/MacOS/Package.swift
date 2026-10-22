// swift-tools-version: 6.4

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "macOS",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(
            name: "macOS",
            targets: ["MacOS"]
        )
    ],
    dependencies: [
        // zencode:package-path
        .package(name: "ZenCODE", path: "../../..")
    ],
    targets: [
        .executableTarget(
            name: "MacOS",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "MacOSTests",
            dependencies: [
                "MacOS",
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
