// swift-tools-version: 6.3

import PackageDescription

let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let package = Package(
    name: "browser-tools-feature",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "browser-tools-feature", targets: ["browser-tools-feature"])
    ],
    dependencies: [
        // zencode:package-path
        .package(path: "../../.."),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "BrowserToolsFeature",
            dependencies: [
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: memberImportVisibilitySettings
        ),
        .executableTarget(
            name: "browser-tools-feature",
            dependencies: ["BrowserToolsFeature"],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "BrowserToolsFeatureTests",
            dependencies: [
                "BrowserToolsFeature",
                .product(name: "FeatureKit", package: "ZenCODE"),
                .product(name: "ToolCore", package: "ZenCODE")
            ],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
