//
//  SwiftFeatureRuntimeDefaults.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//

import Foundation
import ToolCore

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
        let supportsPersistentSession: Bool
        let invocationTimeoutSeconds: TimeInterval?

        init(
            id: String,
            executableName: String,
            description: String? = nil,
            isCore: Bool = false,
            sourceRelativePath: String? = nil,
            tools: [ToolDescriptor],
            toolNamePrefixes: [String] = [],
            toolNameAliases: [String] = [],
            discoversToolsAtRuntime: Bool = false,
            supportsPersistentSession: Bool = false,
            invocationTimeoutSeconds: TimeInterval? = nil
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
            self.supportsPersistentSession = supportsPersistentSession
            self.invocationTimeoutSeconds = invocationTimeoutSeconds
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
                supportsPersistentSession: record.supportsPersistentSession,
                invocationTimeoutSeconds: record.invocationTimeoutSeconds,
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
            ToolDescriptor.canonicalized(tools).map(DirectToolDescriptor.init)
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

    static func bundledFeatureDefinitions() -> [BundledFeatureDefinition] {
        SwiftBundledFeatureCatalog.definitions()
    }

    static func bundledFeatureDefinition(id: String) -> BundledFeatureDefinition? {
        bundledFeatureDefinitions().first { $0.id == id }
    }

    /// Catalog records merged with the packages installed under the user feature
    /// root.
    ///
    /// Optional features are never resolved as executables shipped next to the
    /// `zen` binary: an entry that has no installed package is reported as not
    /// available, with an issue explaining how to install it.
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
        let featureRootURL = optionalFeatureRootURL(
            searchRoots: searchRoots,
            fileManager: fileManager
        )

        let bundledRecords = bundledDefinitions.map { feature in
            SwiftFeatureRecord(
                id: feature.id,
                displayName: nil,
                description: feature.description,
                source: .bundled,
                isCore: feature.isCore,
                executableURL: notInstalledExecutableURL(
                    definition: feature,
                    featureRootURL: featureRootURL
                ),
                manifestURL: nil,
                manifestEnabled: state.bundledFeatureIsEnabled(id: feature.id),
                executableAvailable: false,
                tools: feature.tools,
                toolNamePrefixes: feature.toolNamePrefixes,
                toolNameAliases: feature.toolNameAliases,
                discoversToolsAtRuntime: feature.discoversToolsAtRuntime,
                supportsPersistentSession: feature.supportsPersistentSession,
                invocationTimeoutSeconds: feature.invocationTimeoutSeconds,
                build: nil,
                generated: nil,
                adoptedFrom: nil,
                issue: optionalFeatureNotInstalledIssue
            )
        }
        .filter { !generatedShadowIDs.contains($0.id) }

        return bundledRecords + generatedRecords
    }

    /// Path the release executable *will* have once the optional feature is
    /// installed. Reporting it keeps `feature.list` output actionable without
    /// implying the binary exists.
    private static func notInstalledExecutableURL(
        definition: BundledFeatureDefinition,
        featureRootURL: URL
    ) -> URL {
        featureRootURL
            .appendingPathComponent(definition.id, isDirectory: true)
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent(definition.executableName)
            .standardizedFileURL
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

    static func sourcePackageRootURL(fileManager: FileManager) -> URL? {
        PackageRootResolver.packageRoot(
            forSourceFilePath: #filePath,
            fileManager: fileManager
        )
    }
}
