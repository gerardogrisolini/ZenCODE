//
//  ZenBundledFeatureCatalog.swift
//  ZenCODE
//

/// Immutable distribution identity for a bundled Swift feature.
///
/// `productName`, target name, built executable name, and installer filename are
/// deliberately the same value. Keeping that invariant here avoids treating
/// those four names as independent compatibility surfaces.
public struct ZenBundledFeatureMetadata: Sendable, Equatable, Hashable {
    public let id: String
    public let productName: String
    public let sourceRelativePath: String
    public let isInstalledOnLinux: Bool

    public init(
        id: String,
        productName: String,
        sourceRelativePath: String,
        isInstalledOnLinux: Bool
    ) {
        self.id = id
        self.productName = productName
        self.sourceRelativePath = sourceRelativePath
        self.isInstalledOnLinux = isInstalledOnLinux
    }
}

/// Stable metadata shared by ZenCODE runtime compatibility checks.
///
/// `Package.swift` and the installer shell catalog cannot import this target,
/// so tests assert their parity with these records. Runtime-specific details
/// such as descriptions, schemas, aliases, and timeouts remain in
/// `SwiftBundledFeatureCatalog`.
public enum ZenBundledFeatureCatalog {
    public static let all: [ZenBundledFeatureMetadata] = [
        ZenBundledFeatureMetadata(
            id: "search-tools",
            productName: "search-tools-feature",
            sourceRelativePath: "Sources/Features/SearchTools",
            isInstalledOnLinux: true
        ),
        ZenBundledFeatureMetadata(
            id: "web-tools",
            productName: "web-tools-feature",
            sourceRelativePath: "Sources/Features/WebTools",
            isInstalledOnLinux: true
        ),
        ZenBundledFeatureMetadata(
            id: "git-tools",
            productName: "git-tools-feature",
            sourceRelativePath: "Sources/Features/GitTools",
            isInstalledOnLinux: true
        ),
        ZenBundledFeatureMetadata(
            id: "swift-tools",
            productName: "swift-tools-feature",
            sourceRelativePath: "Sources/Features/SwiftTools",
            // Preserve the existing Linux installer product set. The SwiftPM
            // product remains available to source-package users on Linux.
            isInstalledOnLinux: false
        ),
        ZenBundledFeatureMetadata(
            id: "xcode-tools",
            productName: "xcode-tools-feature",
            sourceRelativePath: "Sources/Features/XcodeTools",
            isInstalledOnLinux: true
        ),
        ZenBundledFeatureMetadata(
            id: "figma-tools",
            productName: "figma-tools-feature",
            sourceRelativePath: "Sources/Features/FigmaTools",
            isInstalledOnLinux: true
        ),
        ZenBundledFeatureMetadata(
            id: "jira-tools",
            productName: "jira-tools-feature",
            sourceRelativePath: "Sources/Features/JiraTools",
            isInstalledOnLinux: true
        )
    ]

    public static func feature(id: String) -> ZenBundledFeatureMetadata? {
        all.first { $0.id == id }
    }

    public static var macOSInstallerProductNames: [String] {
        all.map(\.productName)
    }

    public static var linuxInstallerProductNames: [String] {
        all
            .filter(\.isInstalledOnLinux)
            .map(\.productName)
    }
}
