//
//  ZenCODESetupRunner+RemoteReset.swift
//  ZenCODE
//

import Foundation

struct RemoteConfigurationResetResult: Equatable {
    let removedURLs: [URL]
    let missingURLs: [URL]
}

extension ZenCODESetupRunner {
    /// Removes the persisted configuration used by remote providers and the
    /// ZenCODE state that depends on it. This intentionally has no dependency
    /// on an inference runtime.
    @discardableResult
    static func resetRemoteConfiguration(
        fileManager: FileManager = .default,
        configurationURLs: [URL]? = nil,
        removalCheckpoint: ((Int) throws -> Void)? = nil
    ) throws -> RemoteConfigurationResetResult {
        let fileURLs = uniqueRemoteConfigurationURLs(
            configurationURLs ?? remoteConfigurationURLs(fileManager: fileManager)
        )
        let supportDirectoryURL = fileURLs.first?.deletingLastPathComponent()
        let result = try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        ) {
            var originalData: [String: Data] = [:]
            var missingURLs: [URL] = []
            for url in fileURLs {
                if fileManager.fileExists(atPath: url.path) {
                    originalData[url.path] = try Data(contentsOf: url)
                } else {
                    missingURLs.append(url)
                }
            }
            let changes = fileURLs.compactMap { url in
                originalData[url.path].map {
                    SensitiveManifestCoordination.Change(
                        url: url,
                        originalData: $0,
                        intendedData: nil
                    )
                }
            }
            let rollbackChanges = changes.map { change in
                SensitiveManifestCoordination.Change(
                    url: change.url,
                    originalData: nil,
                    intendedData: change.originalData
                )
            }
            if let supportDirectoryURL {
                try SensitiveManifestCoordination.beginTransaction(
                    rollbackChanges,
                    supportDirectoryURL: supportDirectoryURL,
                    fileManager: fileManager
                )
            }

            var removedURLs: [URL] = []
            do {
                for url in fileURLs where originalData[url.path] != nil {
                    try fileManager.removeItem(at: url)
                    removedURLs.append(url)
                    try removalCheckpoint?(removedURLs.count)
                }
                if let supportDirectoryURL {
                    #if canImport(Darwin) || canImport(Glibc)
                    try SensitiveFilePermissions.synchronizeDirectory(
                        at: supportDirectoryURL
                    )
                    #endif
                    try SensitiveManifestCoordination.clearTransaction(
                        supportDirectoryURL: supportDirectoryURL,
                        fileManager: fileManager
                    )
                }
            } catch {
                let removalError = error
                var rollbackFailures: [String] = []
                if let supportDirectoryURL {
                    do {
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
                }
                for url in fileURLs.reversed() where originalData[url.path] != nil {
                    do {
                        let data = originalData[url.path]
                        let currentData = fileManager.fileExists(atPath: url.path)
                            ? try Data(contentsOf: url)
                            : nil
                        if currentData == data { continue }
                        guard currentData == nil, let data else {
                            throw ZenCODESupportFileServiceError.manifestRollbackConflict(url)
                        }
                        try SensitiveFilePermissions.writeDurably(
                            data,
                            to: url,
                            fileManager: fileManager
                        )
                    } catch {
                        rollbackFailures.append(error.localizedDescription)
                    }
                }
                guard rollbackFailures.isEmpty else {
                    throw ZenCODESupportFileServiceError.manifestCommitRollbackFailed(
                        commit: removalError.localizedDescription,
                        rollback: rollbackFailures.joined(separator: "; ")
                    )
                }
                if let supportDirectoryURL {
                    try SensitiveManifestCoordination.clearTransaction(
                        supportDirectoryURL: supportDirectoryURL,
                        fileManager: fileManager
                    )
                }
                throw removalError
            }
            return RemoteConfigurationResetResult(
                removedURLs: removedURLs,
                missingURLs: missingURLs
            )
        }
        printRemoteConfigurationResetResult(result)
        return result
    }

    static func remoteConfigurationURLs(fileManager: FileManager = .default) -> [URL] {
        [
            AgentsContextService(fileManager: fileManager).globalAgentsFileURL(),
            SavedSessionsStore(fileManager: fileManager).sessionsFileURL(),
            AgentProfileStore.agentsManifestURL(fileManager: fileManager),
            AgentSettingsManifestStore.settingsURL(fileManager: fileManager),
            AgentPermissionsManifestStore.permissionsURL(fileManager: fileManager)
        ]
    }

    private static func uniqueRemoteConfigurationURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { url in
            seen.insert(url.path).inserted
        }
    }

    private static func printRemoteConfigurationResetResult(
        _ result: RemoteConfigurationResetResult
    ) {
        AgentOutput.standardError.writeString("Remote configuration reset completed.\n")
        printRemoteConfigurationURLs(title: "Removed", urls: result.removedURLs)
        if result.removedURLs.isEmpty {
            printRemoteConfigurationURLs(title: "Missing", urls: result.missingURLs)
        }
    }

    private static func printRemoteConfigurationURLs(title: String, urls: [URL]) {
        guard !urls.isEmpty else {
            return
        }
        AgentOutput.standardError.writeString("\(title):\n")
        for url in urls {
            AgentOutput.standardError.writeString("- \(url.path)\n")
        }
    }
}
