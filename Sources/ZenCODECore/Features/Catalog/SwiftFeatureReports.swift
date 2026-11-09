//
//  SwiftFeatureReports.swift
//  ZenCODE
//
//  Records, statuses and operation reports of the Swift feature catalog.
//

import Foundation
import ToolCore

public struct SwiftFeatureRecord: Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let isCore: Bool
    public let executableURL: URL
    public let manifestURL: URL?
    public let manifestEnabled: Bool
    public let executableAvailable: Bool
    public let tools: [ToolDescriptor]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let supportsPersistentSession: Bool
    public let invocationTimeoutSeconds: TimeInterval?
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let adoptedFrom: String?
    public let issue: String?

    public var enabled: Bool {
        manifestEnabled && executableAvailable
    }

    public var isAdopted: Bool {
        adoptedFrom != nil
    }
}

public struct SwiftFeatureStatus: Codable, Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let isCore: Bool
    public let adoptedFrom: String?
    public let editable: Bool
    public let adoptable: Bool
    public let enabled: Bool
    public let available: Bool
    public let executablePath: String
    public let manifestPath: String?
    public let tools: [String]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let toolCount: Int
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let issue: String?

    public init(
        id: String,
        displayName: String?,
        description: String?,
        source: SwiftFeatureBundleSource,
        isCore: Bool = false,
        adoptedFrom: String? = nil,
        editable: Bool? = nil,
        adoptable: Bool? = nil,
        enabled: Bool,
        available: Bool,
        executablePath: String,
        manifestPath: String?,
        tools: [String],
        toolNamePrefixes: [String],
        toolNameAliases: [String],
        discoversToolsAtRuntime: Bool,
        build: SwiftFeatureBuildManifest?,
        generated: SwiftFeatureGeneratedManifest?,
        issue: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.source = source
        self.isCore = isCore
        self.adoptedFrom = adoptedFrom?.nilIfBlank
        self.editable = editable ?? (source == .generated && !isCore)
        self.adoptable = adoptable ?? (source == .bundled && !isCore)
        self.enabled = enabled
        self.available = available
        self.executablePath = executablePath
        self.manifestPath = manifestPath
        self.tools = tools
        self.toolNamePrefixes = toolNamePrefixes
        self.toolNameAliases = toolNameAliases
        self.discoversToolsAtRuntime = discoversToolsAtRuntime
        self.toolCount = tools.count
        self.build = build
        self.generated = generated
        self.issue = issue
    }
}

public struct SwiftFeatureValidationReport: Codable, Sendable {
    public let ok: Bool
    public let id: String?
    public let manifestPath: String
    public let executablePath: String?
    public let errors: [String]
    public let warnings: [String]
    public let tools: [String]

    public init(
        id: String?,
        manifestPath: String,
        executablePath: String?,
        errors: [String],
        warnings: [String],
        tools: [String]
    ) {
        self.ok = errors.isEmpty
        self.id = id
        self.manifestPath = manifestPath
        self.executablePath = executablePath
        self.errors = errors
        self.warnings = warnings
        self.tools = tools
    }
}

public struct SwiftFeatureBuildReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let command: [String]
    public let workingDirectory: String
    public let executablePath: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
}

public struct SwiftFeatureScaffoldReport: Codable, Sendable {
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let packagePath: String
    public let sourcePath: String
    public let toolName: String
    public let ok: Bool?
    public let built: Bool?
    public let enabled: Bool?
    public let validation: SwiftFeatureValidationReport?
    public let build: SwiftFeatureBuildReport?

    public init(
        id: String,
        directoryPath: String,
        manifestPath: String,
        packagePath: String,
        sourcePath: String,
        toolName: String,
        ok: Bool? = nil,
        built: Bool? = nil,
        enabled: Bool? = nil,
        validation: SwiftFeatureValidationReport? = nil,
        build: SwiftFeatureBuildReport? = nil
    ) {
        self.id = id
        self.directoryPath = directoryPath
        self.manifestPath = manifestPath
        self.packagePath = packagePath
        self.sourcePath = sourcePath
        self.toolName = toolName
        self.ok = ok
        self.built = built
        self.enabled = enabled
        self.validation = validation
        self.build = build
    }
}

public struct SwiftFeatureInstallReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let sourcePath: String
    public let destinationPath: String
    public let manifestPath: String
    public let copied: Bool
    public let built: Bool
    public let enabled: Bool
    public let validation: SwiftFeatureValidationReport
    public let build: SwiftFeatureBuildReport?
}

public struct SwiftFeatureDeleteReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let removed: Bool
    public let wasEnabled: Bool
}

public struct SwiftFeatureAdoptReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let adoptedFrom: String
    public let sourcePath: String
    public let destinationPath: String
    public let manifestPath: String
    public let packagePath: String
    public let sourcePaths: [String]
    public let enabled: Bool
    public let copied: Bool
}

public struct SwiftFeaturePromotionReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let sourcePath: String
    public let checkoutPath: String
    public let gitRoot: String
    public let gitBranch: String?
    public let destinationPath: String
    public let manifestPath: String
    public let packagePath: String
    public let catalogPaths: [String]
    public let changedPaths: [String]
    public let overwritten: Bool
    public let built: Bool
    public let listedTools: [String]
    public let rolledBack: Bool
    public let validation: SwiftFeatureValidationReport
    public let build: SwiftFeatureBuildReport?
    public let warnings: [String]

    public init(
        ok: Bool = true,
        id: String,
        sourcePath: String,
        checkoutPath: String,
        gitRoot: String,
        gitBranch: String?,
        destinationPath: String,
        manifestPath: String,
        packagePath: String,
        catalogPaths: [String],
        changedPaths: [String],
        overwritten: Bool,
        built: Bool,
        listedTools: [String] = [],
        rolledBack: Bool = false,
        validation: SwiftFeatureValidationReport,
        build: SwiftFeatureBuildReport?,
        warnings: [String] = []
    ) {
        self.ok = ok
        self.id = id
        self.sourcePath = sourcePath
        self.checkoutPath = checkoutPath
        self.gitRoot = gitRoot
        self.gitBranch = gitBranch
        self.destinationPath = destinationPath
        self.manifestPath = manifestPath
        self.packagePath = packagePath
        self.catalogPaths = catalogPaths
        self.changedPaths = changedPaths
        self.overwritten = overwritten
        self.built = built
        self.listedTools = listedTools
        self.rolledBack = rolledBack
        self.validation = validation
        self.build = build
        self.warnings = warnings
    }

    /// Compatibility alias used by clients that call the destination the
    /// promoted path.
    public var promotedPath: String { destinationPath }
}
public struct SwiftFeatureEditReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let source: SwiftFeatureBundleSource
    public let adopted: Bool
    public let adoptedFrom: String?
    public let directoryPath: String
    public let manifestPath: String
    public let packagePath: String?
    public let sourcePaths: [String]
    public let executablePath: String
    public let enabled: Bool
    public let instructions: [String]
    public let warnings: [String]
    public let adopt: SwiftFeatureAdoptReport?
}
