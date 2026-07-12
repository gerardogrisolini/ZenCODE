//
//  SwiftBundledFeatureCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import ZenPackageMetadata

/// Static metadata and tool declarations for features distributed with ZenCODE.
enum SwiftBundledFeatureCatalog {
    static func definitions() -> [SwiftFeatureRuntime.BundledFeatureDefinition] {
        let search = metadata(for: "search-tools")
        let web = metadata(for: "web-tools")
        let git = metadata(for: "git-tools")
        let swift = metadata(for: "swift-tools")
        let jira = metadata(for: "jira-tools")
        let xcode = metadata(for: "xcode-tools")
        let figma = metadata(for: "figma-tools")

        return [
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
                tools: webToolDescriptors(),
                invocationTimeoutSeconds: 180
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: git.id,
                executableName: git.productName,
                description: "Run Git operations: status, diff, commit, branch, log, and more.",
                sourceRelativePath: git.sourceRelativePath,
                tools: gitToolDescriptors()
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: swift.id,
                executableName: swift.productName,
                description: "Build, test, run, and inspect SwiftPM packages.",
                sourceRelativePath: swift.sourceRelativePath,
                tools: swiftToolDescriptors(),
                invocationTimeoutSeconds: 3_660
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: jira.id,
                executableName: jira.productName,
                description: "Query and manage Jira issues and projects.",
                sourceRelativePath: jira.sourceRelativePath,
                tools: jiraToolDescriptors(),
                invocationTimeoutSeconds: 660
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: XcodeToolIntegration.featureID,
                executableName: xcode.productName,
                description: "Build, test, preview, and inspect Xcode projects.",
                sourceRelativePath: xcode.sourceRelativePath,
                tools: [],
                toolNamePrefixes: [
                    XcodeToolIntegration.toolPrefix,
                    XcodeToolIntegration.legacyToolPrefix
                ],
                toolNameAliases: XcodeToolIntegration.toolNameAliases,
                discoversToolsAtRuntime: true,
                invocationTimeoutSeconds: 3_660
            ),
            SwiftFeatureRuntime.BundledFeatureDefinition(
                id: figma.id,
                executableName: figma.productName,
                description: "Inspect Figma files, frames, and design data.",
                sourceRelativePath: figma.sourceRelativePath,
                tools: [],
                toolNamePrefixes: ["figma."],
                discoversToolsAtRuntime: true
            )
        ]
    }

    private static func metadata(for id: String) -> ZenBundledFeatureMetadata {
        guard let feature = ZenBundledFeatureCatalog.feature(id: id) else {
            preconditionFailure("Missing bundled feature metadata for \(id).")
        }
        return feature
    }

    private static func searchToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.localSearchDescriptors.map(\.toolDescriptor) + [
            ToolDescriptor(
                name: "search.grep",
                description: "Searches text with grep from a local path. Use context for surrounding lines and filesOnly to list only matching file paths.",
                inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#
            )
        ]
    }

    private static func webToolDescriptors() -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "web.search",
                description: "Searches the public web and returns matching results with titles, URLs, and snippets.",
                inputSchema: #"{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"number"},"domains":{"type":"array","items":{"type":"string"}}},"required":["query"]}"#
            ),
            ToolDescriptor(
                name: "web.fetch",
                description: "Fetches an HTTP or HTTPS URL and returns response metadata plus a UTF-8 text preview.",
                inputSchema: #"{"type":"object","properties":{"url":{"type":"string"},"maxBytes":{"type":"number"},"timeoutSeconds":{"type":"number"}},"required":["url"]}"#
            )
        ]
    }

    private static func gitToolDescriptors() -> [ToolDescriptor] {
        #if canImport(Darwin) || canImport(Glibc)
        DirectToolCatalog.macOSProcessDescriptors
            .filter { $0.name.hasPrefix("git.") }
            .map(\.toolDescriptor)
        #else
        []
        #endif
    }

    private static func swiftToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.swiftDescriptors.map(\.toolDescriptor)
    }

    private static func jiraToolDescriptors() -> [ToolDescriptor] {
        [
            ToolDescriptor(
                name: "jira.search",
                description: "Searches Jira issues by issue key, issue URL, or text and returns selectable issue summaries.",
                inputSchema: #"{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}"#
            ),
            ToolDescriptor(
                name: "jira.read",
                description: "Loads a Jira issue and returns task context for the model without creating a local task.",
                inputSchema: #"{"type":"object","properties":{"issueKey":{"type":"string"},"issue_key":{"type":"string"},"key":{"type":"string"},"url":{"type":"string"},"query":{"type":"string"},"includeRaw":{"type":"boolean"},"include_raw":{"type":"boolean"}}}"#
            ),
            ToolDescriptor(
                name: "jira.signOut",
                description: "Clears the persisted Jira API token used by the Jira tools.",
                inputSchema: #"{"type":"object","properties":{}}"#
            )
        ]
    }
}
