// swift-tools-version: 6.4

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
        .package(name: "ZenCODE", path: "../../.."),
        // The Linux sign-in server runs on SwiftNIO, already pinned by ZenCODE.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0")
    ],
    targets: [
        .executableTarget(
            name: "figma-tools-feature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "FigmaToolsFeatureTests",
            dependencies: [
                "figma-tools-feature",
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
