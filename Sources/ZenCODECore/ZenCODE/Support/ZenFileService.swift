//
//  ZenFileService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct ZenFileResult: Sendable {
    public let supportDirectoryURL: URL
    public let agentsFileURL: URL
    public let memoryFileURL: URL
    public let agentsManifestURL: URL
    public let settingsFileURL: URL
    public let createdFilenames: [String]
    public let preservedFilenames: [String]

    public init(
        supportDirectoryURL: URL,
        agentsFileURL: URL,
        memoryFileURL: URL,
        agentsManifestURL: URL,
        settingsFileURL: URL,
        createdFilenames: [String],
        preservedFilenames: [String]
    ) {
        self.supportDirectoryURL = supportDirectoryURL
        self.agentsFileURL = agentsFileURL
        self.memoryFileURL = memoryFileURL
        self.agentsManifestURL = agentsManifestURL
        self.settingsFileURL = settingsFileURL
        self.createdFilenames = createdFilenames
        self.preservedFilenames = preservedFilenames
    }
}

public enum ZenFileService {
    public static let requiredFilenames: [String] = [
        AgentsContextService.filename,
        MemoryService.filename,
        AgentProfileStore.manifestFilename,
        AgentSettingsManifestStore.settingsFilename
    ]

    @discardableResult
    public static func ensureBaseFiles(
        fileManager: FileManager = .default
    ) throws -> ZenFileResult {
        let supportDirectoryURL = supportDirectoryURL(fileManager: fileManager)
        try fileManager.createDirectory(
            at: supportDirectoryURL,
            withIntermediateDirectories: true
        )

        var createdFilenames: [String] = []
        var preservedFilenames: [String] = []

        let agentsService = AgentsContextService(fileManager: fileManager)
        let agentsFileURL = agentsService.globalAgentsFileURL()
        let hadAgentsFile = fileManager.fileExists(atPath: agentsFileURL.path)
        guard let ensuredAgentsFileURL = agentsService.ensureGlobalAgentsFileExists() else {
            throw ZenCODESupportFileServiceError.unableToCreate(agentsFileURL)
        }
        record(
            filename: AgentsContextService.filename,
            existedBefore: hadAgentsFile,
            createdFilenames: &createdFilenames,
            preservedFilenames: &preservedFilenames
        )

        let memoryService = MemoryService(fileManager: fileManager)
        let memoryFileURL = memoryService.globalMemoryFileURL()
        let hadMemoryFile = fileManager.fileExists(atPath: memoryFileURL.path)
        let ensuredMemoryFileURL = try memoryService.ensureGlobalMemoryFileExists()
        record(
            filename: MemoryService.filename,
            existedBefore: hadMemoryFile,
            createdFilenames: &createdFilenames,
            preservedFilenames: &preservedFilenames
        )

        let agentsManifestURL = AgentProfileStore.agentsManifestURL(fileManager: fileManager)
        let hadAgentsManifest = fileManager.fileExists(atPath: agentsManifestURL.path)
        let ensuredAgentsManifestURL = try AgentProfileStore.ensureDefaultManifestExists(
            fileManager: fileManager
        )
        record(
            filename: AgentProfileStore.manifestFilename,
            existedBefore: hadAgentsManifest,
            createdFilenames: &createdFilenames,
            preservedFilenames: &preservedFilenames
        )

        let settingsFileURL = AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
        if fileManager.fileExists(atPath: settingsFileURL.path) {
            preservedFilenames.append(AgentSettingsManifestStore.settingsFilename)
        }

        return ZenFileResult(
            supportDirectoryURL: supportDirectoryURL,
            agentsFileURL: ensuredAgentsFileURL,
            memoryFileURL: ensuredMemoryFileURL,
            agentsManifestURL: ensuredAgentsManifestURL,
            settingsFileURL: settingsFileURL,
            createdFilenames: createdFilenames,
            preservedFilenames: preservedFilenames
        )
    }

    @discardableResult
    public static func ensureRequiredFiles(
        settingsManifest: AgentSettingsManifest?,
        overwriteSettings: Bool = false,
        fileManager: FileManager = .default
    ) throws -> ZenFileResult {
        let baseResult = try ensureBaseFiles(fileManager: fileManager)
        guard let settingsManifest else {
            return baseResult
        }

        let hadSettingsFile = fileManager.fileExists(atPath: baseResult.settingsFileURL.path)
        if overwriteSettings || !hadSettingsFile {
            try saveSettings(settingsManifest, fileManager: fileManager)
        }

        var createdFilenames = baseResult.createdFilenames
        var preservedFilenames = baseResult.preservedFilenames.filter {
            $0 != AgentSettingsManifestStore.settingsFilename
        }
        if !(overwriteSettings && hadSettingsFile) {
            record(
                filename: AgentSettingsManifestStore.settingsFilename,
                existedBefore: hadSettingsFile,
                createdFilenames: &createdFilenames,
                preservedFilenames: &preservedFilenames
            )
        }

        return ZenFileResult(
            supportDirectoryURL: baseResult.supportDirectoryURL,
            agentsFileURL: baseResult.agentsFileURL,
            memoryFileURL: baseResult.memoryFileURL,
            agentsManifestURL: baseResult.agentsManifestURL,
            settingsFileURL: baseResult.settingsFileURL,
            createdFilenames: createdFilenames,
            preservedFilenames: preservedFilenames
        )
    }

    public static func saveSettings(
        _ manifest: AgentSettingsManifest,
        fileManager: FileManager = .default
    ) throws {
        try AgentSettingsManifestStore.save(
            manifest,
            to: AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
        )
    }

    public static func supportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .standardizedFileURL
    }

    private static func record(
        filename: String,
        existedBefore: Bool,
        createdFilenames: inout [String],
        preservedFilenames: inout [String]
    ) {
        if existedBefore {
            preservedFilenames.append(filename)
        } else {
            createdFilenames.append(filename)
        }
    }
}

public enum ZenCODESupportFileServiceError: LocalizedError {
    case unableToCreate(URL)

    public var errorDescription: String? {
        switch self {
        case let .unableToCreate(url):
            return "Unable to create ZenCODE support file: \(url.path)"
        }
    }
}
