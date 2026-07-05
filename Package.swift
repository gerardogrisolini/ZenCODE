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
        name: "LocalToolsSupport",
        targets: ["LocalToolsSupport"]
    ),
    .executable(
        name: "zen",
        targets: ["zen"]
    ),
    .executable(
        name: "search-tools-feature",
        targets: ["search-tools-feature"]
    ),
    .executable(
        name: "web-tools-feature",
        targets: ["web-tools-feature"]
    ),
    .executable(
        name: "git-tools-feature",
        targets: ["git-tools-feature"]
    ),
    .executable(
        name: "swift-tools-feature",
        targets: ["swift-tools-feature"]
    ),
    .executable(
        name: "xcode-tools-feature",
        targets: ["xcode-tools-feature"]
    ),
    .executable(
        name: "figma-tools-feature",
        targets: ["figma-tools-feature"]
    ),
    .executable(
        name: "jira-tools-feature",
        targets: ["jira-tools-feature"]
    )
]

var zenCODEDependencies: [Target.Dependency] = [
    "ZenCODECore",
    "ZenCODESetup",
    "ZenPackageMetadata",
    "search-tools-feature",
    "web-tools-feature",
    "git-tools-feature",
    "swift-tools-feature",
    "xcode-tools-feature",
    "figma-tools-feature",
    "jira-tools-feature"
]

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
            dependencies: ["zen"],
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
            "LocalToolsSupport",
            "ZenPackageMetadata"
        ],
        swiftSettings: [
            .define("SWIFTPM_NON_SANDBOX_TUI")
        ]
    ),
    .target(
        name: "FeatureKit",
        dependencies: []
    ),
    .target(
        name: "ToolCore",
        dependencies: []
    ),
    .target(
        name: "FeatureMCPBridgeKit",
        dependencies: [
            "ToolCore",
            .product(name: "Crypto", package: "swift-crypto")
        ]
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
        exclude: zenCODEExclude,
        swiftSettings: zenCODESwiftSettings
    ),
    .testTarget(
        name: "ZenCODECoreTests",
        dependencies: [
            "ZenCODECore",
            "FeatureMCPBridgeKit"
        ]
    ),
    .testTarget(
        name: "ZenCODESetupTests",
        dependencies: [
            "ZenCODECore",
            "ZenCODESetup"
        ]
    ),
    .executableTarget(
        name: "search-tools-feature",
        dependencies: [
            "FeatureKit",
            "LocalToolsSupport"
        ],
        path: "Sources/Features/SearchTools"
    ),
    .executableTarget(
        name: "web-tools-feature",
        dependencies: ["FeatureKit"],
        path: "Sources/Features/WebTools"
    ),
    .executableTarget(
        name: "git-tools-feature",
        dependencies: ["FeatureKit"],
        path: "Sources/Features/GitTools"
    ),
    .executableTarget(
        name: "swift-tools-feature",
        dependencies: ["FeatureKit"],
        path: "Sources/Features/SwiftTools"
    ),
    .executableTarget(
        name: "xcode-tools-feature",
        dependencies: [
            "FeatureKit",
            "ToolCore",
            "FeatureMCPBridgeKit"
        ],
        path: "Sources/Features/XcodeTools"
    ),
    .executableTarget(
        name: "figma-tools-feature",
        dependencies: [
            "FeatureKit",
            "ToolCore",
            "FeatureMCPBridgeKit"
        ],
        path: "Sources/Features/FigmaTools"
    ),
    .executableTarget(
        name: "jira-tools-feature",
        dependencies: [
            "FeatureKit",
            "ToolCore"
        ],
        path: "Sources/Features/JiraTools"
    )
]

if localMLXEnabled {
    targets += [
        .target(
            name: "MLXServerCore",
            dependencies: [
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
            dependencies: ["MLXServerCore"]
        ),
        .testTarget(
            name: "MLXServerSetupTests",
            dependencies: ["MLXServerSetup"]
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
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", branch: "main")
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
