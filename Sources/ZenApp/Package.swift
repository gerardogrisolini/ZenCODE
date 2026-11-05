// swift-tools-version: 6.4

import PackageDescription

// ZenApp is the SwiftUI macOS app of ZenCODE. It is a standalone package
// outside the root graph (like ZenCRON and the standalone features): it
// consumes ZenCODECore and ToolCore through a path dependency on the root
// package and adds its own presentation modules on top.

/// Every target enables `MemberImportVisibility`, as the root package does.
let memberImportVisibilitySettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility")
]

let zenCODECore: Target.Dependency = .product(name: "ZenCODECore", package: "ZenCODE")
let toolCore: Target.Dependency = .product(name: "ToolCore", package: "ZenCODE")
let markdown: Target.Dependency = .product(name: "Markdown", package: "swift-markdown")

let package = Package(
    name: "ZenApp",
    platforms: [.macOS(.v26)],
    products: [
        // The SwiftUI app: `swift run --package-path Sources/ZenApp ZenCODE`.
        .executable(name: "ZenCODE", targets: ["ZenCODEApp"]),
        // One library product per library target, only so that Xcode creates
        // a scheme for each of them: SwiftUI previews cannot run in the
        // executable target, so the `#Preview`s of these targets need a
        // library scheme of their own. Nothing depends on these products.
        .library(name: "ZenAppTheme", targets: ["ZenAppTheme"]),
        .library(name: "ZenAppMarkdown", targets: ["ZenAppMarkdown"]),
        .library(name: "ZenAppSession", targets: ["ZenAppSession"]),
        .library(name: "ZenAppTranscript", targets: ["ZenAppTranscript"]),
        .library(name: "ZenAppControls", targets: ["ZenAppControls"])
    ],
    dependencies: [
        .package(name: "ZenCODE", path: "../.."),
        // Already in the root graph (the Markdown parser of ZenCODECore).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.8.0")
    ],
    targets: [
        .target(
            name: "ZenAppTheme",
            swiftSettings: memberImportVisibilitySettings
        ),
        .target(
            name: "ZenAppMarkdown",
            dependencies: ["ZenAppTheme", markdown],
            swiftSettings: memberImportVisibilitySettings
        ),
        .target(
            name: "ZenAppSession",
            dependencies: [zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .target(
            name: "ZenAppTranscript",
            dependencies: ["ZenAppTheme", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .target(
            name: "ZenAppControls",
            dependencies: ["ZenAppTheme", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .executableTarget(
            name: "ZenCODEApp",
            dependencies: [
                "ZenAppTheme",
                "ZenAppMarkdown",
                "ZenAppSession",
                "ZenAppTranscript",
                "ZenAppControls",
                zenCODECore,
                toolCore
            ],
            // Assets/icon.svg at the repository root is the source of truth;
            // this copy is what the app loads to set its Dock icon, and a
            // test keeps the two byte-identical. `.copy` keeps the SVG as is.
            resources: [.copy("Resources/icon.svg")],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenAppThemeTests",
            dependencies: ["ZenAppTheme"],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenAppMarkdownTests",
            dependencies: ["ZenAppMarkdown", "ZenAppTheme", markdown],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenAppSessionTests",
            dependencies: ["ZenAppSession", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenAppTranscriptTests",
            dependencies: ["ZenAppTranscript", "ZenAppTheme", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenAppControlsTests",
            dependencies: ["ZenAppControls", "ZenAppTheme", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        ),
        .testTarget(
            name: "ZenCODEAppTests",
            dependencies: ["ZenCODEApp", "ZenAppSession", "ZenAppControls", zenCODECore, toolCore],
            swiftSettings: memberImportVisibilitySettings
        )
    ]
)
