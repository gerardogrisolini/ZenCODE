//
//  SwiftBundledFeatureCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import ZenPackageMetadata

/// Runtime metadata and tool declarations for the optional feature packages
/// shipped in the ZenCODE source tree.
///
/// These are **not** executables distributed next to `zen`. Each entry is a
/// self-contained SwiftPM package under `sourceRelativePath` that the user can
/// install from source into `~/.zencode/features/<id>/`, where it behaves
/// exactly like a package created by the local feature Builder.
///
/// Distribution identity (`id`, `productName`, `sourceRelativePath`,
/// `isInstalledOnLinux`) stays in `ZenBundledFeatureCatalog`; only runtime
/// details such as descriptions, schemas, prefixes, aliases, and invocation
/// timeouts live here.
enum SwiftBundledFeatureCatalog {
    static func definitions() -> [SwiftFeatureRuntime.BundledFeatureDefinition] {
        let search = metadata(for: "search-tools")
        let web = metadata(for: "web-tools")
        let browser = metadata(for: "browser-tools")
        let git = metadata(for: "git-tools")
        let swift = metadata(for: "swift-tools")
        let jira = metadata(for: "jira-tools")
        #if os(macOS)
        let xcode = metadata(for: "xcode-tools")
        #endif
        let figma = metadata(for: "figma-tools")
        let desktop = metadata(for: "desktop-tools")

        var definitions = [
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: search.id,
                executableName: search.productName,
                description: "Find files by glob and search file contents with grep.",
                sourceRelativePath: search.sourceRelativePath,
                tools: searchToolDescriptors()
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: web.id,
                executableName: web.productName,
                description: "Search the web and fetch URLs as text.",
                sourceRelativePath: web.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["web."],
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 180
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: browser.id,
                executableName: browser.productName,
                description: "Search Google and visit pages using a real Chrome browser.",
                sourceRelativePath: browser.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["browser."],
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 180
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: git.id,
                executableName: git.productName,
                description: "Run Git operations: status, diff, commit, branch, log, and more.",
                sourceRelativePath: git.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["git."],
                discoversToolsAtRuntime: true
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: swift.id,
                executableName: swift.productName,
                description: "Build, test, run, and inspect SwiftPM packages.",
                sourceRelativePath: swift.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["swift."],
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 3_660
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: jira.id,
                executableName: jira.productName,
                description: "Query and manage Jira issues and projects.",
                sourceRelativePath: jira.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["jira."],
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 660
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: figma.id,
                executableName: figma.productName,
                description: "Inspect Figma files, frames, and design data.",
                sourceRelativePath: figma.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["figma."],
                discoversToolsAtRuntime: true
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: desktop.id,
                executableName: desktop.productName,
                description: "Control the local macOS desktop: system and window state, PNG screenshots, pointer, keyboard, clipboard, and app management.",
                sourceRelativePath: desktop.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["desktop."],
                discoversToolsAtRuntime: true,
                // Screenshots, app launches, and explicit waits are all bounded
                // by the tool's own limits, but a single invocation can still
                // legitimately span several seconds of desktop interaction.
                invocationTimeoutSeconds: 180
            )
        ]
        #if os(macOS)
        definitions.insert(
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: xcode.id,
                executableName: xcode.productName,
                description: "Build, test, preview, and inspect Xcode projects.",
                sourceRelativePath: xcode.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["xcode.", "Xcode"],
                toolNameAliases: [
                    "BuildProject",
                    "DocumentationSearch",
                    "ExecuteSnippet",
                    "GetBuildLog",
                    "GetTestList",
                    "RenderPreview",
                    "RunAllTests",
                    "RunSomeTests"
                ],
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 3_660
            ),
            at: 6
        )
        #endif
        return definitions
    }

    private static func metadata(for id: String) -> ZenBundledFeatureMetadata {
        guard let feature = ZenBundledFeatureCatalog.feature(id: id) else {
            preconditionFailure("Missing bundled feature metadata for \(id).")
        }
        return feature
    }

    private static func searchToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.localSearchDescriptors.map(\.toolDescriptor)
    }


}
