//
//  SwiftFeatureRuntimeDefaults.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation

extension SwiftFeatureRuntime {
    struct BundledFeatureDefinition: Sendable {
        let id: String
        let executableName: String
        let description: String?
        let isCore: Bool
        let sourceRelativePath: String?
        let tools: [ToolDescriptor]
        let toolNamePrefixes: [String]
        let toolNameAliases: [String]
        let discoversToolsAtRuntime: Bool

        init(
            id: String,
            executableName: String,
            description: String? = nil,
            isCore: Bool = false,
            sourceRelativePath: String? = nil,
            tools: [ToolDescriptor],
            toolNamePrefixes: [String] = [],
            toolNameAliases: [String] = [],
            discoversToolsAtRuntime: Bool = false
        ) {
            self.id = id
            self.executableName = executableName
            self.description = description?.nilIfBlank
            self.isCore = isCore
            self.sourceRelativePath = sourceRelativePath?.nilIfBlank
            self.tools = ToolDescriptor.canonicalized(tools)
            self.toolNamePrefixes = toolNamePrefixes
            self.toolNameAliases = toolNameAliases
            self.discoversToolsAtRuntime = discoversToolsAtRuntime
        }

        func bundle(executableURL: URL) -> SwiftFeatureBundle {
            SwiftFeatureBundle(
                id: id,
                executableURL: executableURL,
                tools: tools,
                toolNamePrefixes: toolNamePrefixes,
                toolNameAliases: toolNameAliases,
                discoversToolsAtRuntime: discoversToolsAtRuntime,
                source: .bundled,
                isCore: isCore
            )
        }
    }

    public static func defaultFeatureBundles(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> [SwiftFeatureBundle] {
        let records = defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        return records.compactMap { record in
            guard record.enabled else {
                return nil
            }
            return SwiftFeatureBundle(
                id: record.id,
                executableURL: record.executableURL,
                tools: record.tools,
                toolNamePrefixes: record.toolNamePrefixes,
                toolNameAliases: record.toolNameAliases,
                discoversToolsAtRuntime: record.discoversToolsAtRuntime,
                source: record.source,
                isCore: record.isCore
            )
        }
    }

    public static func defaultFeatureToolDescriptors(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        includeDisabled: Bool = false
    ) -> [DirectToolDescriptor] {
        let records = defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        let tools = records
            .filter { includeDisabled || $0.enabled }
            .flatMap(\.tools)
        return DirectToolExecutor.canonicalized(
            ToolDescriptor.canonicalized(tools).map {
                DirectToolDescriptor(
                    name: $0.name,
                    description: $0.description,
                    inputSchema: $0.inputSchema
                )
            }
        )
    }

    public static func defaultFeatureStatuses(
        searchRoots: [URL]? = nil,
        fileManager: FileManager = .default,
        includeTools: Bool = true,
        includeDisabled: Bool = true
    ) -> [SwiftFeatureStatus] {
        defaultFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        .filter { includeDisabled || $0.enabled }
        .map { record in
            status(
                from: record,
                tools: includeTools ? record.tools.map(\.name) : []
            )
        }
    }

    private static func bundledFeatureBundles(
        fileManager: FileManager
    ) -> [SwiftFeatureBundle] {
        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        return bundledFeatureDefinitions()
            .filter { state.bundledFeatureIsEnabled(id: $0.id) }
            .compactMap { definition in
                guard let executableURL = availableBundledExecutableURL(
                    named: definition.executableName,
                    fileManager: fileManager
                ) else {
                    return nil
                }
                return definition.bundle(executableURL: executableURL)
            }
    }

    static func bundledFeatureDefinitions() -> [BundledFeatureDefinition] {
        [
            BundledFeatureDefinition(
                id: "search-tools",
                executableName: "search-tools-feature",
                description: "Find files by glob and search file contents with grep.",
                sourceRelativePath: "Sources/Features/SearchTools",
                tools: bundledSearchToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "web-tools",
                executableName: "web-tools-feature",
                description: "Search the web and fetch URLs as text.",
                sourceRelativePath: "Sources/Features/WebTools",
                tools: bundledWebToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "git-tools",
                executableName: "git-tools-feature",
                description: "Run Git operations: status, diff, commit, branch, log, and more.",
                sourceRelativePath: "Sources/Features/GitTools",
                tools: bundledGitToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "swift-tools",
                executableName: "swift-tools-feature",
                description: "Build, test, run, and inspect SwiftPM packages.",
                sourceRelativePath: "Sources/Features/SwiftTools",
                tools: bundledSwiftToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "jira-tools",
                executableName: "jira-tools-feature",
                description: "Query and manage Jira issues and projects.",
                sourceRelativePath: "Sources/Features/JiraTools",
                tools: bundledJiraToolDescriptors()
            ),
            BundledFeatureDefinition(
                id: "xcode-tools",
                executableName: "xcode-tools-feature",
                description: "Build, test, preview, and inspect Xcode projects.",
                sourceRelativePath: "Sources/Features/XcodeTools",
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
                discoversToolsAtRuntime: true
            ),
            BundledFeatureDefinition(
                id: "figma-tools",
                executableName: "figma-tools-feature",
                description: "Inspect Figma files, frames, and design data.",
                sourceRelativePath: "Sources/Features/FigmaTools",
                tools: [],
                toolNamePrefixes: ["figma."],
                discoversToolsAtRuntime: true
            )
        ]
    }

    static func bundledFeatureDefinition(id: String) -> BundledFeatureDefinition? {
        bundledFeatureDefinitions().first { $0.id == id }
    }

    static func defaultFeatureRecords(
        searchRoots: [URL]?,
        fileManager: FileManager
    ) -> [SwiftFeatureRecord] {
        let state = SwiftFeatureStateStore.load(fileManager: fileManager)
        let bundledDefinitions = bundledFeatureDefinitions()
        let coreBundledIDs = Set(bundledDefinitions.filter(\.isCore).map(\.id))
        let generatedRecords = SwiftFeatureRegistry.discoverFeatureRecords(
            searchRoots: searchRoots,
            fileManager: fileManager
        )
        .filter { !coreBundledIDs.contains($0.id) }
        let generatedShadowIDs = Set(generatedRecords.map(\.id))

        let bundledRecords = bundledDefinitions.map { feature in
            let executableURL = bundledExecutableStatusURL(
                named: feature.executableName,
                fileManager: fileManager
            )
            return SwiftFeatureRecord(
                id: feature.id,
                displayName: nil,
                description: feature.description,
                source: .bundled,
                isCore: feature.isCore,
                executableURL: executableURL,
                manifestURL: nil,
                manifestEnabled: state.bundledFeatureIsEnabled(id: feature.id),
                executableAvailable: fileManager.isExecutableFile(atPath: executableURL.path),
                tools: feature.tools,
                toolNamePrefixes: feature.toolNamePrefixes,
                toolNameAliases: feature.toolNameAliases,
                discoversToolsAtRuntime: feature.discoversToolsAtRuntime,
                build: nil,
                generated: nil,
                adoptedFrom: nil,
                issue: nil
            )
        }
        .filter { !generatedShadowIDs.contains($0.id) }

        return bundledRecords + generatedRecords
    }

    static func status(
        from record: SwiftFeatureRecord,
        tools: [String]
    ) -> SwiftFeatureStatus {
        status(
            id: record.id,
            displayName: record.displayName,
            description: record.description,
            source: record.source,
            isCore: record.isCore,
            adoptedFrom: record.adoptedFrom,
            editable: record.source == .generated && !record.isCore,
            adoptable: record.source == .bundled && !record.isCore,
            executableURL: record.executableURL,
            enabled: record.enabled,
            available: record.executableAvailable,
            manifestPath: record.manifestURL?.path,
            issue: record.issue,
            tools: tools,
            toolNamePrefixes: record.toolNamePrefixes,
            toolNameAliases: record.toolNameAliases,
            discoversToolsAtRuntime: record.discoversToolsAtRuntime,
            build: record.build,
            generated: record.generated
        )
    }

    static func status(
        from feature: SwiftFeatureBundle,
        enabled: Bool,
        available: Bool,
        manifestPath: String?,
        issue: String?,
        tools: [String]
    ) -> SwiftFeatureStatus {
        status(
            id: feature.id,
            displayName: nil,
            description: nil,
            source: feature.source,
            isCore: feature.isCore,
            adoptedFrom: nil,
            editable: feature.source == .generated && !feature.isCore,
            adoptable: feature.source == .bundled && !feature.isCore,
            executableURL: feature.executableURL,
            enabled: enabled,
            available: available,
            manifestPath: manifestPath,
            issue: issue,
            tools: tools,
            toolNamePrefixes: feature.toolNamePrefixes,
            toolNameAliases: feature.toolNameAliases,
            discoversToolsAtRuntime: feature.discoversToolsAtRuntime,
            build: nil,
            generated: nil
        )
    }

    static func status(
        id: String,
        displayName: String?,
        description: String?,
        source: SwiftFeatureBundleSource,
        isCore: Bool,
        adoptedFrom: String?,
        editable: Bool,
        adoptable: Bool,
        executableURL: URL,
        enabled: Bool,
        available: Bool,
        manifestPath: String?,
        issue: String?,
        tools: [String],
        toolNamePrefixes: [String],
        toolNameAliases: [String],
        discoversToolsAtRuntime: Bool,
        build: SwiftFeatureBuildManifest?,
        generated: SwiftFeatureGeneratedManifest?
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: displayName,
            description: description,
            source: source,
            isCore: isCore,
            adoptedFrom: adoptedFrom,
            editable: editable,
            adoptable: adoptable,
            enabled: enabled,
            available: available,
            executablePath: executableURL.path,
            manifestPath: manifestPath,
            tools: tools.sorted(),
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: toolNameAliases,
            discoversToolsAtRuntime: discoversToolsAtRuntime,
            build: build,
            generated: generated,
            issue: issue
        )
    }

    private static func bundledSearchToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.localSearchDescriptors.map(\.toolDescriptor) + [
            ToolDescriptor(
                name: "search.grep",
                description: "Searches text with grep from a local path. Use context for surrounding lines and filesOnly to list only matching file paths.",
                inputSchema: #"{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"maxResults":{"type":"number"},"max_results":{"type":"number"},"context":{"type":"number"},"filesOnly":{"type":"boolean"},"files_only":{"type":"boolean"}},"required":["pattern"]}"#
            )
        ]
    }

    private static func bundledWebToolDescriptors() -> [ToolDescriptor] {
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

    private static func bundledGitToolDescriptors() -> [ToolDescriptor] {
        #if canImport(Darwin) || canImport(Glibc)
        DirectToolCatalog.macOSProcessDescriptors
            .filter { $0.name.hasPrefix("git.") }
            .map(\.toolDescriptor)
        #else
        []
        #endif
    }

    private static func bundledSwiftToolDescriptors() -> [ToolDescriptor] {
        DirectToolCatalog.swiftDescriptors.map(\.toolDescriptor)
    }

    private static func bundledJiraToolDescriptors() -> [ToolDescriptor] {
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

    private static func availableBundledExecutableURL(
        named executableName: String,
        fileManager: FileManager
    ) -> URL? {
        for executableURL in bundledExecutableCandidateURLs(
            named: executableName,
            fileManager: fileManager
        ) {
            if fileManager.isExecutableFile(atPath: executableURL.path) {
                return executableURL
            }
        }
        return nil
    }

    private static func bundledExecutableStatusURL(
        named executableName: String,
        fileManager: FileManager
    ) -> URL {
        availableBundledExecutableURL(
            named: executableName,
            fileManager: fileManager
        ) ?? bundledExecutableCandidateURLs(
            named: executableName,
            fileManager: fileManager
        ).first
            ?? URL(fileURLWithPath: executableName).standardizedFileURL
    }

    static func bundledExecutableCandidateURLs(
        named executableName: String,
        fileManager: FileManager,
        workingDirectoryURL explicitWorkingDirectoryURL: URL? = nil,
        pathEnvironment: String? = ProcessInfo.processInfo.environment["PATH"],
        commandLineArgument: String? = CommandLine.arguments.first,
        executableDirectoryURLs explicitExecutableDirectoryURLs: [URL]? = nil
    ) -> [URL] {
        var seenPaths = Set<String>()
        let executableDirectories = explicitExecutableDirectoryURLs
            ?? defaultExecutableDirectoryURLs(
                pathEnvironment: pathEnvironment,
                commandLineArgument: commandLineArgument,
                fileManager: fileManager
            )
        let workingDirectoryURL = explicitWorkingDirectoryURL?.standardizedFileURL
            ?? URL(
                fileURLWithPath: fileManager.currentDirectoryPath,
                isDirectory: true
            ).standardizedFileURL
        let buildRootURLs = [
            workingDirectoryURL,
            sourcePackageRootURL(fileManager: fileManager)
        ]
            .compactMap { $0 }
            .map { $0.appendingPathComponent(".build", isDirectory: true) }
        let buildProductDirectories = buildRootURLs.flatMap {
            swiftPMBuildProductDirectories(
                buildDirectoryURL: $0,
                fileManager: fileManager
            )
        }
        let installedFeatureDirectories = executableDirectories.flatMap {
            bundledFeatureInstallDirectories(binaryDirectoryURL: $0)
        }
        let ancestorDirectories = executableDirectories.flatMap { directoryURL in
            var directories = [directoryURL]
            var parentURL = directoryURL
            for _ in 0..<4 {
                parentURL = parentURL.deletingLastPathComponent()
                directories.append(parentURL)
            }
            return directories
        }
        let candidateDirectories = installedFeatureDirectories
            + ancestorDirectories
            + buildProductDirectories

        return candidateDirectories.compactMap { directoryURL in
            let executableURL = directoryURL
                .appendingPathComponent(executableName)
                .standardizedFileURL
            guard seenPaths.insert(executableURL.path).inserted else {
                return nil
            }
            return executableURL
        }
    }

    private static func defaultExecutableDirectoryURLs(
        pathEnvironment: String?,
        commandLineArgument: String?,
        fileManager: FileManager
    ) -> [URL] {
        let bundleDirectories = [
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle.main.executableURL?
                .resolvingSymlinksInPath()
                .deletingLastPathComponent()
        ].compactMap { $0 }
        let commandLineDirectories = commandLineArgument.map {
            commandLineExecutableDirectoryURLs(
                argument: $0,
                pathEnvironment: pathEnvironment,
                fileManager: fileManager
            )
        } ?? []
        return bundleDirectories + commandLineDirectories
    }

    private static func commandLineExecutableDirectoryURLs(
        argument: String,
        pathEnvironment: String?,
        fileManager: FileManager
    ) -> [URL] {
        guard !argument.isEmpty else {
            return []
        }
        if argument.contains("/") {
            let executableURL = URL(fileURLWithPath: argument)
            return [
                executableURL.standardizedFileURL.deletingLastPathComponent(),
                executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            ]
        }

        for directoryURL in executableSearchPathDirectories(pathEnvironment: pathEnvironment) {
            let executableURL = directoryURL.appendingPathComponent(argument)
            guard fileManager.isExecutableFile(atPath: executableURL.path) else {
                continue
            }
            return [
                directoryURL.standardizedFileURL,
                executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
            ]
        }
        return []
    }

    private static func executableSearchPathDirectories(
        pathEnvironment: String?
    ) -> [URL] {
        guard let pathEnvironment else {
            return []
        }
        return pathEnvironment
            .split(separator: ":", omittingEmptySubsequences: true)
            .map {
                URL(fileURLWithPath: String($0), isDirectory: true)
                    .standardizedFileURL
            }
    }

    private static func bundledFeatureInstallDirectories(
        binaryDirectoryURL: URL
    ) -> [URL] {
        let binaryDirectoryURL = binaryDirectoryURL.standardizedFileURL
        let packageDirectoryURL = binaryDirectoryURL.deletingLastPathComponent()
        return [
            binaryDirectoryURL,
            binaryDirectoryURL.appendingPathComponent("features", isDirectory: true),
            binaryDirectoryURL.appendingPathComponent("zen-features", isDirectory: true),
            packageDirectoryURL.appendingPathComponent("features", isDirectory: true),
            packageDirectoryURL.appendingPathComponent("zen-features", isDirectory: true),
            packageDirectoryURL.appendingPathComponent("share", isDirectory: true)
                .appendingPathComponent("ZenCODE", isDirectory: true)
                .appendingPathComponent("features", isDirectory: true)
        ]
    }

    static func sourcePackageRootURL(fileManager: FileManager) -> URL? {
        var directoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .standardizedFileURL
        for _ in 0..<8 {
            if fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent("Package.swift").path
            ) {
                return directoryURL
            }
            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                return nil
            }
            directoryURL = parentURL
        }
        return nil
    }

    private static func swiftPMBuildProductDirectories(
        buildDirectoryURL: URL,
        fileManager: FileManager
    ) -> [URL] {
        var directories = [
            buildDirectoryURL.appendingPathComponent("debug", isDirectory: true),
            buildDirectoryURL.appendingPathComponent("release", isDirectory: true)
        ]
        guard let children = try? fileManager.contentsOfDirectory(
            at: buildDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return directories
        }

        for childURL in children {
            guard (try? childURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            directories.append(childURL.appendingPathComponent("debug", isDirectory: true))
            directories.append(childURL.appendingPathComponent("release", isDirectory: true))
        }
        return directories
    }
}
