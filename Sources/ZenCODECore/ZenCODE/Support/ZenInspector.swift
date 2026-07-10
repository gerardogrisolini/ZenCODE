//
//  ZenInspector.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum SetupStatus: Equatable, Sendable {
    case ready(settingsFileURL: URL)
    case missingSettings(settingsFileURL: URL)
    case invalidSettings(settingsFileURL: URL, message: String)
    case missingAgents(agentsFileURL: URL)
    case invalidAgents(agentsFileURL: URL, message: String)
    case unavailable(message: String)

    public var requiresSetup: Bool {
        switch self {
        case .ready:
            return false
        case .missingSettings(settingsFileURL: _),
             .invalidSettings(settingsFileURL: _, message: _),
             .missingAgents(agentsFileURL: _),
             .invalidAgents(agentsFileURL: _, message: _),
             .unavailable(message: _):
            return true
        }
    }

    public var message: String {
        switch self {
        case .ready:
            return "ZenCODE is configured."
        case let .missingSettings(settingsFileURL: url):
            return "Missing settings.json at \(url.path)."
        case let .invalidSettings(settingsFileURL: _, message: message):
            return "Invalid settings.json: \(message)"
        case let .missingAgents(agentsFileURL: url):
            return "Missing agents.json at \(url.path)."
        case let .invalidAgents(agentsFileURL: _, message: message):
            return "Invalid agents.json: \(message)"
        case let .unavailable(message: message):
            return message
        }
    }
}

public enum ZenInspector {
    public static func status(
        ensureBaseFiles: Bool = true,
        fileManager: FileManager = .default
    ) -> SetupStatus {
        do {
            let supportFiles: ZenFileResult
            if ensureBaseFiles {
                supportFiles = try ZenFileService.ensureBaseFiles(
                    fileManager: fileManager
                )
            } else {
                supportFiles = ZenFileResult(
                    supportDirectoryURL: ZenFileService.supportDirectoryURL(
                        fileManager: fileManager
                    ),
                    agentsFileURL: AgentsContextService(fileManager: fileManager)
                        .globalAgentsFileURL(),
                    agentsManifestURL: AgentProfileStore.agentsManifestURL(
                        fileManager: fileManager
                    ),
                    settingsFileURL: AgentSettingsManifestStore.settingsURL(
                        fileManager: fileManager
                    ),
                    createdFilenames: [],
                    preservedFilenames: []
                )
            }

            guard fileManager.fileExists(atPath: supportFiles.agentsManifestURL.path) else {
                return .missingAgents(agentsFileURL: supportFiles.agentsManifestURL)
            }

            do {
                _ = try AgentProfileStore.loadRequired(fileManager: fileManager)
            } catch {
                return .invalidAgents(
                    agentsFileURL: supportFiles.agentsManifestURL,
                    message: error.localizedDescription
                )
            }

            guard fileManager.fileExists(atPath: supportFiles.settingsFileURL.path) else {
                return .missingSettings(settingsFileURL: supportFiles.settingsFileURL)
            }

            do {
                _ = try AgentSettingsManifestStore.loadRequired(
                    from: supportFiles.settingsFileURL
                )
            } catch {
                return .invalidSettings(
                    settingsFileURL: supportFiles.settingsFileURL,
                    message: error.localizedDescription
                )
            }

            return .ready(settingsFileURL: supportFiles.settingsFileURL)
        } catch {
            return .unavailable(message: error.localizedDescription)
        }
    }
}
