//
//  PersistedAgentConfigurationSnapshot.swift
//  ZenCODE
//

import Foundation

/// A coordinated read of the two manifests that jointly define runtime model
/// and tool grants. Holding the shared manifest lock across both decodes prevents
/// startup from combining settings from one setup transaction with profiles
/// from another.
struct PersistedAgentConfigurationSnapshot {
    let settings: AgentSettingsManifest
    let profiles: [AgentProfile]

    static func loadRequired(fileManager: FileManager = .default) throws -> Self {
        let settingsURL = AgentSettingsManifestStore.settingsURL(fileManager: fileManager)
        let profilesURL = AgentProfileStore.agentsManifestURL(fileManager: fileManager)
        let supportDirectoryURL = settingsURL.deletingLastPathComponent()
        guard profilesURL.deletingLastPathComponent() == supportDirectoryURL else {
            throw AgentSettingsManifestStoreError.unreadableFile(
                settingsURL,
                CocoaError(.fileReadInvalidFileName)
            )
        }
        return try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: supportDirectoryURL,
            fileManager: fileManager
        ) {
            Self(
                settings: try AgentSettingsManifestStore.loadRequiredUnlocked(from: settingsURL),
                profiles: try AgentProfileStore.loadRequiredUnlocked(
                    from: profilesURL,
                    fileManager: fileManager
                )
            )
        }
    }
}
