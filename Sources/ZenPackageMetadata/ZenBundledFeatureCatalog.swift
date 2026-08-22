//
//  ZenBundledFeatureCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

public struct ZenBundledFeatureMetadata: Sendable, Equatable, Hashable {
    public let id: String
    public let productName: String
    public let sourceRelativePath: String
    public let isInstalledOnLinux: Bool

    public init(id: String, productName: String, sourceRelativePath: String, isInstalledOnLinux: Bool) {
        self.id = id
        self.productName = productName
        self.sourceRelativePath = sourceRelativePath
        self.isInstalledOnLinux = isInstalledOnLinux
    }
}

public enum ZenBundledFeatureCatalog {
    public static let declarativeCatalogFilename = "feature-catalog.json"

    public static let all: [ZenBundledFeatureMetadata] = [
        ZenBundledFeatureMetadata(
            id: "browser-tools",
            productName: "browser-tools-feature",
            sourceRelativePath: "Sources/Features/BrowserTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "desktop-tools",
            productName: "desktop-tools-feature",
            sourceRelativePath: "Sources/Features/DesktopTools",
            isInstalledOnLinux: false,
        ),
        ZenBundledFeatureMetadata(
            id: "figma-tools",
            productName: "figma-tools-feature",
            sourceRelativePath: "Sources/Features/FigmaTools",
            isInstalledOnLinux: false,
        ),
        ZenBundledFeatureMetadata(
            id: "git-tools",
            productName: "git-tools-feature",
            sourceRelativePath: "Sources/Features/GitTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "jira-tools",
            productName: "jira-tools-feature",
            sourceRelativePath: "Sources/Features/JiraTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "search-tools",
            productName: "search-tools-feature",
            sourceRelativePath: "Sources/Features/SearchTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "swift-tools",
            productName: "swift-tools-feature",
            sourceRelativePath: "Sources/Features/SwiftTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "web-tools",
            productName: "web-tools-feature",
            sourceRelativePath: "Sources/Features/WebTools",
            isInstalledOnLinux: true,
        ),
        ZenBundledFeatureMetadata(
            id: "xcode-tools",
            productName: "xcode-tools-feature",
            sourceRelativePath: "Sources/Features/XcodeTools",
            isInstalledOnLinux: false,
        )
    ]

    public static func feature(id: String) -> ZenBundledFeatureMetadata? {
        all.first { $0.id == id }
    }

    public static var linuxInstallerProductNames: [String] {
        all.filter(\.isInstalledOnLinux).map(\.productName)
    }
}
