//
//  ZenCODESetupRunner+RemoteReset.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

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
        configurationURLs: [URL]? = nil
    ) throws -> RemoteConfigurationResetResult {
        let fileURLs = uniqueRemoteConfigurationURLs(
            configurationURLs ?? remoteConfigurationURLs(fileManager: fileManager)
        )

        var removedURLs: [URL] = []
        var missingURLs: [URL] = []
        for url in fileURLs {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
                removedURLs.append(url)
            } else {
                missingURLs.append(url)
            }
        }

        let result = RemoteConfigurationResetResult(
            removedURLs: removedURLs,
            missingURLs: missingURLs
        )
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
