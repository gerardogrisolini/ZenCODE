// swift-tools-version: 6.3

import PackageDescription

/// Swift 6.3 `MemberImportVisibility` requires every file to import the modules
/// that define the members it uses, instead of relying on transitively visible
/// members. Enable it uniformly for every local Swift target and combine it with
/// any target-specific settings rather than replacing them.
let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let products: [Product] = [
    .library(
        name: "ZenCODECore",
        targets: ["ZenCODECore"]
    ),
    .library(
        name: "FeatureKit",
        targets: ["FeatureKit"]
    ),
    .library(
        name: "ToolCore",
        targets: ["ToolCore"]
    ),
    .library(
        name: "FeatureMCPBridgeKit",
        targets: ["FeatureMCPBridgeKit"]
    ),
    .library(
        name: "LocalToolsSupport",
        targets: ["LocalToolsSupport"]
    ),
    .executable(
        name: "zen",
        targets: ["zen"]
    )
]

let zenCODEDependencies: [Target.Dependency] = [
    "ZenCODECore",
    "ZenPackageMetadata"
]

let targets: [Target] = [
    .target(
        name: "ZenPackageMetadata",
        dependencies: [],
        swiftSettings: memberImportVisibilitySettings
    ),
    .target(
        name: "ZenCODECore",
        dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Markdown", package: "swift-markdown"),
            // The remote-generation substrate owns HTTP/SSE and WebSocket
            // transport directly on SwiftNIO. Keep this deliberately narrower
            // than AsyncHTTPClient/WebSocketKit: no HTTP/2, tracing, or Apple-
            // only transport-services graph is needed by the shared Core API.
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            "FeatureKit",
            "ToolCore",
            "FeatureMCPBridgeKit",
            "LocalToolsSupport",
            "ZenPackageMetadata"
        ],
        swiftSettings: memberImportVisibilitySettings
    ),
    .target(
        name: "FeatureKit",
        dependencies: ["ToolCore"],
        swiftSettings: memberImportVisibilitySettings
    ),
    .target(
        name: "ToolCore",
        dependencies: [],
        swiftSettings: memberImportVisibilitySettings
    ),
    .target(
        name: "FeatureMCPBridgeKit",
        dependencies: [
            "FeatureKit",
            "ToolCore",
            .product(name: "Crypto", package: "swift-crypto")
        ],
        swiftSettings: memberImportVisibilitySettings
    ),
    .target(
        name: "LocalToolsSupport",
        dependencies: ["FeatureKit", "ToolCore"],
        swiftSettings: memberImportVisibilitySettings
    ),
    .executableTarget(
        name: "zen",
        dependencies: zenCODEDependencies,
        swiftSettings: memberImportVisibilitySettings
    ),
    // Built as a test dependency so the persistence suite can exercise two
    // genuinely independent processes without exposing engine internals.
    .executableTarget(
        name: "MemoryPersistenceTestHelper",
        dependencies: ["ZenCODECore"],
        swiftSettings: memberImportVisibilitySettings
    ),
    .testTarget(
        name: "ZenCODECoreTests",
        dependencies: [
            "ZenCODECore",
            "MemoryPersistenceTestHelper",
            "FeatureMCPBridgeKit",
            "FeatureKit",
            "LocalToolsSupport",
            "ZenPackageMetadata",
            "ToolCore",
            .product(name: "Markdown", package: "swift-markdown"),
            // Local deterministic transport tests host small NIO HTTP and
            // WebSocket servers; production dependencies remain Core-only.
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOWebSocket", package: "swift-nio")
        ],
        swiftSettings: memberImportVisibilitySettings
    ),
    .testTarget(
        name: "ToolCoreTests",
        dependencies: ["ToolCore"],
        swiftSettings: memberImportVisibilitySettings
    ),
    .testTarget(
        name: "FeatureKitTests",
        dependencies: ["FeatureKit", "ToolCore"],
        swiftSettings: memberImportVisibilitySettings
    ),
    .testTarget(
        name: "FeatureMCPBridgeKitTests",
        dependencies: [
            "FeatureMCPBridgeKit",
            "ToolCore"
        ],
        swiftSettings: memberImportVisibilitySettings
    ),
    .testTarget(
        name: "LocalToolsSupportTests",
        dependencies: [
            "LocalToolsSupport",
            "FeatureKit"
        ],
        swiftSettings: memberImportVisibilitySettings
    )
]

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.0")
]

let package = Package(
    name: "ZenCODE",
    platforms: [
        .macOS(.v26)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
