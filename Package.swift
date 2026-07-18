// swift-tools-version: 6.3

import Foundation
import PackageDescription

func environmentPath(_ name: String) -> String? {
    guard let rawValue = Context.environment[name], !rawValue.isEmpty else {
        return nil
    }
    return URL(fileURLWithPath: rawValue).standardizedFileURL.path
}

func buildFlag(_ name: String, default defaultValue: Bool) -> Bool {
    guard let rawValue = Context.environment[name]?.lowercased() else {
        return defaultValue
    }
    switch rawValue {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}

let localMLXEnabled: Bool = {
    #if os(macOS)
    buildFlag("ZENCODE_BUILD_LOCAL_MLX", default: true)
    #else
    false
    #endif
}()

let ds4RootPath = environmentPath("ZENCODE_DS4_ROOT") ?? environmentPath("DS4_ROOT")
let localDS4Enabled = buildFlag("ZENCODE_BUILD_DS4", default: ds4RootPath != nil)

if localDS4Enabled {
    guard let ds4RootPath else {
        fatalError("DS4 support requires ZENCODE_DS4_ROOT=/path/to/ds4 or DS4_ROOT=/path/to/ds4.")
    }
    guard FileManager.default.fileExists(atPath: "\(ds4RootPath)/ds4.h") else {
        fatalError("DS4 support requires ds4.h under \(ds4RootPath).")
    }
}

let ds4ShimCSettings: [CSetting] = ds4RootPath.map {
    [.unsafeFlags(["-I", $0])]
} ?? []

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

var products: [Product] = []

if localMLXEnabled {
    products += [
        .library(
            name: "MLXServerCore",
            targets: ["MLXServerCore"]
        ),
        .library(
            name: "MLXServerSetup",
            targets: ["MLXServerSetup"]
        )
    ]
}

products += [
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
    "LocalRuntimeSupport",
    "ZenCODESetup",
    "ZenPackageMetadata"
]

for feature in bundledFeatureTargetDefinitions {
    zenCODEDependencies.append(.target(name: feature.executableName))
}

var zenCODESwiftSettings: [SwiftSetting] = [
    .define("SWIFTPM_NON_SANDBOX_TUI")
]

var zenCODEExclude: [String] = []

if localMLXEnabled {
    zenCODEDependencies += [
        "MLXServerCore",
        "MLXServerSetup",
        .product(name: "MLXLMCommon", package: "mlx-swift-lm")
    ]
    zenCODESwiftSettings.append(.define("ZENCODE_LOCAL_MLX"))
} else {
    zenCODEExclude += [
        "Commands/ZenCODEMLXCommand.swift",
        "Commands/ZenCODEMLXResetCommands.swift",
        "LocalMLX"
    ]
}

if localDS4Enabled {
    zenCODEDependencies.append("DS4RuntimeShim")
    zenCODESwiftSettings.append(.define("ZENCODE_LOCAL_DS4"))
} else {
    zenCODEExclude += [
        "Commands/ZenCODEDS4Command.swift",
        "LocalDS4",
        "Setup/ZenCODESetupMenuRunner+DS4.swift"
    ]
}

var targets: [Target] = []

if localDS4Enabled {
    targets.append(
        .target(
            name: "DS4RuntimeShim",
            dependencies: [],
            cSettings: ds4ShimCSettings
        )
    )
    targets.append(
        .testTarget(
            name: "ZenCODEDS4Tests",
            dependencies: [
                "zen",
                "ZenCODECore"
            ],
            swiftSettings: [.define("ZENCODE_LOCAL_DS4")]
        )
    )
}

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
        dependencies: ["FeatureKit"],
        path: "Sources/Features/BrowserTools/Feature"
    ),
    .target(
        name: "LocalToolsSupport",
        dependencies: ["FeatureKit"]
    ),
    .target(
        name: "LocalRuntimeSupport",
        dependencies: ["ZenCODECore"]
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
        exclude: zenCODEExclude,
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
        name: "ZenCODELocalRuntimeTests",
        dependencies: [
            "LocalRuntimeSupport",
            "ZenCODECore"
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

if localMLXEnabled {
    targets += [
        .target(
            name: "MLXServerCore",
            dependencies: [
                "ToolCore",
                "ZenPackageMetadata",
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ]
        ),
        .target(
            name: "MLXServerSetup",
            dependencies: [
                "ZenCODECore",
                "MLXServerCore",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        ),
        .testTarget(
            name: "MLXServerCoreTests",
            dependencies: [
                "MLXServerCore",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm")
            ]
        ),
        .testTarget(
            name: "MLXServerSetupTests",
            dependencies: [
                "MLXServerSetup",
                "MLXServerCore",
                .product(name: "HuggingFace", package: "swift-huggingface")
            ]
        )
    ]
}

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
]

if localMLXEnabled {
    dependencies += [
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", from: "1.3.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.31.3")),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", .upToNextMinor(from: "3.31.4"))
    ]
}

let package = Package(
    name: "ZenCODE",
    platforms: [
        .macOS(.v26)
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
