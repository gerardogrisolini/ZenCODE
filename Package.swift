// swift-tools-version: 6.3

import PackageDescription

/// Bundled feature products intentionally use the same name for their SwiftPM
/// target, product, built executable, and installed filename. Keep the
/// package-only build details together so those names and source paths are not
/// repeated across products, `zen` dependencies, and target declarations.
struct BundledFeatureTargetDefinition {
    let executableName: String
    let sourceRelativePath: String
    let dependencies: [Target.Dependency]
    /// The executable may live below the copied feature root when a bundled
    /// feature also contains a reusable library target.
    let executableTargetRelativePath: String?

    init(
        executableName: String,
        sourceRelativePath: String,
        dependencies: [Target.Dependency],
        executableTargetRelativePath: String? = nil
    ) {
        self.executableName = executableName
        self.sourceRelativePath = sourceRelativePath
        self.dependencies = dependencies
        self.executableTargetRelativePath = executableTargetRelativePath
    }
}

let bundledFeatureTargetDefinitions: [BundledFeatureTargetDefinition] = [
    BundledFeatureTargetDefinition(
        executableName: "search-tools-feature",
        sourceRelativePath: "Sources/Features/SearchTools",
        dependencies: ["FeatureKit", "LocalToolsSupport"]
    ),
    BundledFeatureTargetDefinition(
        executableName: "web-tools-feature",
        sourceRelativePath: "Sources/Features/WebTools",
        dependencies: ["FeatureKit"]
    ),
    BundledFeatureTargetDefinition(
        executableName: "browser-tools-feature",
        sourceRelativePath: "Sources/Features/BrowserTools",
        dependencies: ["BrowserToolsFeature"],
        executableTargetRelativePath: "Sources/Features/BrowserTools/Executable"
    ),
    BundledFeatureTargetDefinition(
        executableName: "git-tools-feature",
        sourceRelativePath: "Sources/Features/GitTools",
        dependencies: ["FeatureKit"]
    ),
    BundledFeatureTargetDefinition(
        executableName: "swift-tools-feature",
        sourceRelativePath: "Sources/Features/SwiftTools",
        dependencies: ["FeatureKit"]
    ),
    BundledFeatureTargetDefinition(
        executableName: "xcode-tools-feature",
        sourceRelativePath: "Sources/Features/XcodeTools",
        dependencies: ["XcodeToolsFeature"],
        executableTargetRelativePath: "Sources/Features/XcodeTools/Executable"
    ),
    BundledFeatureTargetDefinition(
        executableName: "figma-tools-feature",
        sourceRelativePath: "Sources/Features/FigmaTools",
        dependencies: ["FeatureKit", "ToolCore", "FeatureMCPBridgeKit"]
    ),
    BundledFeatureTargetDefinition(
        executableName: "jira-tools-feature",
        sourceRelativePath: "Sources/Features/JiraTools",
        dependencies: ["FeatureKit", "ToolCore"]
    )
]

var products: [Product] = [
    .library(
        name: "ZenCODECore",
        targets: ["ZenCODECore"]
    ),
    .library(
        name: "ZenCODESetup",
        targets: ["ZenCODESetup"]
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
        name: "XcodeToolsFeature",
        targets: ["XcodeToolsFeature"]
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

products += bundledFeatureTargetDefinitions.map {
    .executable(name: $0.executableName, targets: [$0.executableName])
}

var zenCODEDependencies: [Target.Dependency] = [
    "ZenCODECore",
    "ZenCODESetup",
    "ZenPackageMetadata"
]

for feature in bundledFeatureTargetDefinitions {
    zenCODEDependencies.append(.target(name: feature.executableName))
}

let zenCODESwiftSettings: [SwiftSetting] = [
    .define("SWIFTPM_NON_SANDBOX_TUI")
]

var targets: [Target] = []

targets += [
    .target(
        name: "ZenPackageMetadata",
        dependencies: []
    ),
    .target(
        name: "ZenCODECore",
        dependencies: [
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Markdown", package: "swift-markdown"),
            "FeatureKit",
            "ToolCore",
            "FeatureMCPBridgeKit",
            "XcodeToolsFeature",
            "LocalToolsSupport",
            "ZenPackageMetadata"
        ],
        swiftSettings: [
            .define("SWIFTPM_NON_SANDBOX_TUI")
        ]
    ),
    .target(
        name: "FeatureKit",
        dependencies: ["ToolCore"]
    ),
    .target(
        name: "ToolCore",
        dependencies: []
    ),
    .target(
        name: "FeatureMCPBridgeKit",
        dependencies: [
            "FeatureKit",
            "ToolCore",
            .product(name: "Crypto", package: "swift-crypto")
        ]
    ),
    .target(
        name: "XcodeToolsFeature",
        dependencies: [
            "FeatureKit",
            "ToolCore",
            "FeatureMCPBridgeKit"
        ],
        path: "Sources/Features/XcodeTools/Feature"
    ),
    .target(
        name: "BrowserToolsFeature",
        dependencies: [
            "FeatureKit",
            .product(name: "Crypto", package: "swift-crypto")
        ],
        path: "Sources/Features/BrowserTools/Feature"
    ),
    .target(
        name: "LocalToolsSupport",
        dependencies: ["FeatureKit"]
    ),
    .target(
        name: "ZenCODESetup",
        dependencies: ["ZenCODECore"],
        swiftSettings: [
            .define("SWIFTPM_NON_SANDBOX_TUI")
        ]
    ),
    .executableTarget(
        name: "zen",
        dependencies: zenCODEDependencies,
        swiftSettings: zenCODESwiftSettings
    ),
    .testTarget(
        name: "ZenCODECoreTests",
        dependencies: [
            "ZenCODECore",
            "FeatureMCPBridgeKit",
            "XcodeToolsFeature",
            "FeatureKit",
            "LocalToolsSupport",
            "ZenPackageMetadata",
            .product(name: "Markdown", package: "swift-markdown")
        ]
    ),
    .testTarget(
        name: "ZenCODESetupTests",
        dependencies: [
            "ZenCODECore",
            "ZenCODESetup"
        ]
    ),
    .testTarget(
        name: "ToolCoreTests",
        dependencies: ["ToolCore"]
    ),
    .testTarget(
        name: "FeatureKitTests",
        dependencies: ["FeatureKit"]
    ),
    .testTarget(
        name: "FeatureMCPBridgeKitTests",
        dependencies: [
            "FeatureMCPBridgeKit",
            "ToolCore"
        ]
    ),
    .testTarget(
        name: "XcodeToolsFeatureTests",
        dependencies: [
            "XcodeToolsFeature",
            "FeatureKit",
            "FeatureMCPBridgeKit",
            "ToolCore"
        ]
    ),
    .testTarget(
        name: "BrowserToolsFeatureTests",
        dependencies: [
            "BrowserToolsFeature",
            "FeatureKit",
            "ZenCODECore"
        ]
    ),
    .testTarget(
        name: "LocalToolsSupportTests",
        dependencies: [
            "LocalToolsSupport",
            "FeatureKit"
        ]
    )
]

targets += bundledFeatureTargetDefinitions.map {
    .executableTarget(
        name: $0.executableName,
        dependencies: $0.dependencies,
        path: $0.executableTargetRelativePath ?? $0.sourceRelativePath
    )
}

let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
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
