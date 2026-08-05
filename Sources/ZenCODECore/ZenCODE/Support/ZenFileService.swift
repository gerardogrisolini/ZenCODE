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
    public let agentsManifestURL: URL
    public let settingsFileURL: URL
    public let createdFilenames: [String]
    public let preservedFilenames: [String]

    public init(
        supportDirectoryURL: URL,
        agentsFileURL: URL,
        agentsManifestURL: URL,
        settingsFileURL: URL,
        createdFilenames: [String],
        preservedFilenames: [String]
    ) {
        self.supportDirectoryURL = supportDirectoryURL
        self.agentsFileURL = agentsFileURL
        self.agentsManifestURL = agentsManifestURL
        self.settingsFileURL = settingsFileURL
        self.createdFilenames = createdFilenames
        self.preservedFilenames = preservedFilenames
    }
}

public enum ZenFileService {
    public static let requiredFilenames: [String] = [
        AgentsContextService.filename,
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
        try ensureRequiredFiles(
            settingsManifest: settingsManifest,
            overwriteSettings: overwriteSettings,
            stagedAgentProfiles: nil,
            fileManager: fileManager
        )
    }

    @discardableResult
    static func ensureRequiredFiles(
        settingsManifest: AgentSettingsManifest?,
        overwriteSettings: Bool,
        stagedAgentProfiles agentProfiles: [AgentProfile]?,
        expectedBaseline: SetupManifestBaseline? = nil,
        fileManager: FileManager = .default,
        commitCheckpoint: ((Int) throws -> Void)? = nil,
        transactionCleanup: ((URL, FileManager) throws -> Void)? = nil
    ) throws -> ZenFileResult {
        guard let settingsManifest else {
            return try ensureBaseFiles(fileManager: fileManager)
        }
        let supportDirectoryURL = supportDirectoryURL(fileManager: fileManager)
        let agentsService = AgentsContextService(fileManager: fileManager)
        let agentsFileURL = agentsService.globalAgentsFileURL()
        let hadAgentsFile = fileManager.fileExists(atPath: agentsFileURL.path)
        guard let ensuredAgentsFileURL = agentsService.ensureGlobalAgentsFileExists() else {
            throw ZenCODESupportFileServiceError.unableToCreate(agentsFileURL)
        }
        return try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        ) {
            let agentsManifestURL = AgentProfileStore.agentsManifestURL(
                fileManager: fileManager
            )
            let settingsFileURL = AgentSettingsManifestStore.settingsURL(
                fileManager: fileManager
            )
            let hadAgentsManifest = fileManager.fileExists(
                atPath: agentsManifestURL.path
            )
            let hadSettingsFile = fileManager.fileExists(
                atPath: settingsFileURL.path
            )
            let settingsWasWritten = overwriteSettings || !hadSettingsFile
            let shouldWriteAgents = agentProfiles != nil
                || settingsWasWritten
                || !hadAgentsManifest

            func currentData(at url: URL) throws -> Data? {
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return try Data(contentsOf: url)
            }
            if (settingsWasWritten || shouldWriteAgents),
               let expectedBaseline,
               try currentData(at: settingsFileURL) != expectedBaseline.settingsData {
                throw ZenCODESupportFileServiceError.manifestChangedConcurrently(
                    settingsFileURL
                )
            }
            if agentProfiles != nil,
               let expectedBaseline,
               try currentData(at: agentsManifestURL) != expectedBaseline.agentsData {
                throw ZenCODESupportFileServiceError.manifestChangedConcurrently(
                    agentsManifestURL
                )
            }

            // Resolve and encode every intended manifest before replacing any
            // file. An invalid existing agents.json therefore cannot leave a
            // newly written settings.json behind.
            let sourceProfiles: [AgentProfile]
            if let agentProfiles {
                sourceProfiles = agentProfiles
            } else if hadAgentsManifest {
                sourceProfiles = try AgentProfileStore.loadRequired(
                    fileManager: fileManager
                )
            } else {
                sourceProfiles = AgentProfileStore.defaultProfiles()
            }
            let preparedAgentProfiles = AgentProfileStore.normalizedAgentsForSave(
                AgentProfileBindingReconciler.reconciledAgents(
                    sourceProfiles,
                    models: settingsManifest.models
                )
            )

            var writes: [CoordinatedManifestWrite] = []
            if settingsWasWritten {
                writes.append(
                    CoordinatedManifestWrite(
                        url: settingsFileURL,
                        data: try AgentSettingsManifestStore.encodedData(
                            for: settingsManifest
                        )
                    )
                )
            }
            if shouldWriteAgents {
                writes.append(
                    CoordinatedManifestWrite(
                        url: agentsManifestURL,
                        data: try AgentProfileStore.encodedData(
                            for: preparedAgentProfiles,
                            fileManager: fileManager
                        )
                    )
                )
            }

            try commitManifests(
                writes,
                fileManager: fileManager,
                checkpoint: commitCheckpoint,
                transactionCleanup: transactionCleanup
            )

            var createdFilenames: [String] = []
            var preservedFilenames: [String] = []
            record(
                filename: AgentsContextService.filename,
                existedBefore: hadAgentsFile,
                createdFilenames: &createdFilenames,
                preservedFilenames: &preservedFilenames
            )
            record(
                filename: AgentProfileStore.manifestFilename,
                existedBefore: hadAgentsManifest,
                createdFilenames: &createdFilenames,
                preservedFilenames: &preservedFilenames
            )
            if !(overwriteSettings && hadSettingsFile) {
                record(
                    filename: AgentSettingsManifestStore.settingsFilename,
                    existedBefore: hadSettingsFile,
                    createdFilenames: &createdFilenames,
                    preservedFilenames: &preservedFilenames
                )
            }

            return ZenFileResult(
                supportDirectoryURL: supportDirectoryURL,
                agentsFileURL: ensuredAgentsFileURL,
                agentsManifestURL: agentsManifestURL,
                settingsFileURL: settingsFileURL,
                createdFilenames: createdFilenames,
                preservedFilenames: preservedFilenames
            )
        }
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

    private struct CoordinatedManifestWrite {
        let url: URL
        let data: Data
    }

    private struct CoordinatedManifestSnapshot {
        let data: Data?
    }

    private static func commitManifests(
        _ writes: [CoordinatedManifestWrite],
        fileManager: FileManager,
        checkpoint: ((Int) throws -> Void)?,
        transactionCleanup: ((URL, FileManager) throws -> Void)?
    ) throws {
        guard !writes.isEmpty else { return }

        var snapshots: [String: CoordinatedManifestSnapshot] = [:]
        for write in writes {
            let path = write.url.standardizedFileURL.path
            if fileManager.fileExists(atPath: path) {
                try SensitiveFilePermissions.hardenExistingFile(
                    at: write.url,
                    fileManager: fileManager
                )
                snapshots[path] = CoordinatedManifestSnapshot(
                    data: try Data(contentsOf: write.url)
                )
            } else {
                snapshots[path] = CoordinatedManifestSnapshot(data: nil)
            }
        }

        let supportDirectoryURL = writes[0].url.deletingLastPathComponent()
        let changes = writes.map { write in
            SensitiveManifestCoordination.Change(
                url: write.url,
                originalData: snapshots[write.url.standardizedFileURL.path]?.data,
                intendedData: write.data
            )
        }
        let rollbackChanges = changes.map { change in
            SensitiveManifestCoordination.Change(
                url: change.url,
                originalData: change.intendedData,
                intendedData: change.originalData
            )
        }
        try SensitiveManifestCoordination.beginTransaction(
            rollbackChanges,
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        )

        do {
            for (index, write) in writes.enumerated() {
                // SensitiveFilePermissions stages and atomically replaces each
                // individual file while the shared cross-process lock prevents
                // settings/profile writers from interleaving this batch.
                try SensitiveFilePermissions.writeDurably(
                    write.data,
                    to: write.url,
                    fileManager: fileManager
                )
                try checkpoint?(index + 1)
            }
            try (transactionCleanup ?? SensitiveManifestCoordination.clearTransaction)(
                supportDirectoryURL,
                fileManager
            )
        } catch {
            let commitError = error
            var rollbackFailures: [String] = []
            do {
                // Re-publish the same rollback-first journal in case commit
                // cleanup unlinked it before reporting a durability error.
                try SensitiveManifestCoordination.ensureTransaction(
                    rollbackChanges,
                    supportDirectoryURL: supportDirectoryURL,
                    fileManager: fileManager
                )
            } catch {
                rollbackFailures.append(
                    "could not persist rollback intent: \(error.localizedDescription)"
                )
            }
            for write in writes.reversed() {
                let path = write.url.standardizedFileURL.path
                do {
                    let currentData: Data?
                    if fileManager.fileExists(atPath: path) {
                        try SensitiveFilePermissions.hardenExistingFile(
                            at: write.url,
                            fileManager: fileManager
                        )
                        currentData = try Data(contentsOf: write.url)
                    } else {
                        currentData = nil
                    }
                    let originalData = snapshots[path]?.data
                    if currentData == originalData { continue }
                    guard currentData == write.data else {
                        throw ZenCODESupportFileServiceError.manifestRollbackConflict(
                            write.url
                        )
                    }
                    if let originalData {
                        try SensitiveFilePermissions.writeDurably(
                            originalData,
                            to: write.url,
                            fileManager: fileManager
                        )
                    } else {
                        try fileManager.removeItem(at: write.url)
                        #if canImport(Darwin) || canImport(Glibc)
                        try SensitiveFilePermissions.synchronizeDirectory(
                            at: supportDirectoryURL
                        )
                        #endif
                    }
                } catch {
                    rollbackFailures.append(error.localizedDescription)
                }
            }
            guard rollbackFailures.isEmpty else {
                throw ZenCODESupportFileServiceError.manifestCommitRollbackFailed(
                    commit: commitError.localizedDescription,
                    rollback: rollbackFailures.joined(separator: "; ")
                )
            }
            try (transactionCleanup ?? SensitiveManifestCoordination.clearTransaction)(
                supportDirectoryURL,
                fileManager
            )
            throw commitError
        }
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
    case manifestChangedConcurrently(URL)
    case manifestRollbackConflict(URL)
    case manifestCommitRollbackFailed(commit: String, rollback: String)

    public var errorDescription: String? {
        switch self {
        case let .unableToCreate(url):
            return "Unable to create ZenCODE support file: \(url.path)"
        case let .manifestChangedConcurrently(url):
            return "Refusing to overwrite a manifest changed during setup: \(url.path)"
        case let .manifestRollbackConflict(url):
            return "Refused to roll back a concurrently modified manifest: \(url.path)"
        case let .manifestCommitRollbackFailed(commit, rollback):
            return "Sensitive manifest commit failed (\(commit)); rollback also failed: \(rollback)"
        }
    }
}
