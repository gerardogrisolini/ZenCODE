//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization

public enum AgentSettingsManifestStore {
    public static let settingsFilename = "settings.json"
    /// Serializes in-process settings writes and read-modify-write updates;
    /// `SensitiveManifestCoordination` supplies the cross-process boundary.
    private static let manifestMutationLock = Mutex<Void>(())

    public static func load() -> AgentSettingsManifest? {
        try? loadRequired()
    }

    public static func preload() {
        _ = load()
    }

    #if DEBUG
    /// Compatibility hook retained for tests that predate uncached settings reads.
    static func resetDefaultCacheForTesting() {}
    #endif

    public static func loadRequired() throws -> AgentSettingsManifest {
        try loadRequired(from: settingsURL())
    }

    public static func loadRequired(
        from url: URL
    ) throws -> AgentSettingsManifest {
        return try SensitiveManifestCoordination.withExclusiveLock(
            supportDirectoryURL: url.deletingLastPathComponent()
        ) {
            try loadRequiredUnlocked(from: url)
        }
    }

    static func loadRequiredUnlocked(
        from url: URL
    ) throws -> AgentSettingsManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentSettingsManifestStoreError.missingFile(url)
        }

        let data: Data
        do {
            try SensitiveFilePermissions.hardenExistingFile(at: url)
            data = try Data(contentsOf: url)
        } catch {
            throw AgentSettingsManifestStoreError.unreadableFile(url, error)
        }

        let manifest: AgentSettingsManifest
        do {
            manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        } catch {
            throw AgentSettingsManifestStoreError.invalidFile(url, error)
        }

        guard manifest.version >= AgentSettingsManifest.minimumSupportedVersion,
              manifest.version <= AgentSettingsManifest.currentVersion else {
            throw AgentSettingsManifestStoreError.unsupportedVersion(
                url,
                manifest.version,
                AgentSettingsManifest.currentVersion
            )
        }
        return manifest
    }

    public static func save(
        _ manifest: AgentSettingsManifest,
        to url: URL = settingsURL()
    ) throws {
        try withManifestMutation(
            supportDirectoryURL: url.deletingLastPathComponent()
        ) {
            try saveUnlocked(manifest, to: url)
        }
    }

    private static func withManifestMutation(
        supportDirectoryURL: URL? = nil,
        _ operation: () throws -> Void
    ) throws {
        try manifestMutationLock.withLock { _ in
            try SensitiveManifestCoordination.withExclusiveLock(
                supportDirectoryURL: supportDirectoryURL,
                operation: operation
            )
        }
    }

    private static func saveUnlocked(
        _ manifest: AgentSettingsManifest,
        to url: URL
    ) throws {
        let data = try encodedData(for: manifest)
        try SensitiveFilePermissions.write(data, to: url)
    }

    static func encodedData(
        for manifest: AgentSettingsManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(manifest)
    }

    public static func saveSelectedModel(
        modelID: String,
        thinkingSelection: AgentThinkingSelection?
    ) throws {
        try withManifestMutation {
            let current = try loadRequiredUnlocked(from: settingsURL())
            try saveUnlocked(
                applying(
                    current,
                    selectedModelID: .some(modelID),
                    selectedThinkingSelection: .some(thinkingSelection)
                ),
                to: settingsURL()
            )
        }
    }

    public static func saveSelectedThinkingSelection(
        _ thinkingSelection: AgentThinkingSelection?
    ) throws {
        try withManifestMutation {
            let current = try loadRequiredUnlocked(from: settingsURL())
            try saveUnlocked(
                applying(current, selectedThinkingSelection: .some(thinkingSelection)),
                to: settingsURL()
            )
        }
    }

    public static func saveChatGPTSubscriptionCredentials(
        _ credentials: CodexAgentCredentials?
    ) throws {
        try withManifestMutation {
            let current = try manifestForCredentialUpdate()
            try saveUnlocked(
                applying(current, chatGPTSubscriptionCredentials: .some(credentials)),
                to: settingsURL()
            )
        }
    }

    public static func saveAnthropicSubscriptionCredentials(
        _ credentials: AnthropicSubscriptionCredentials?
    ) throws {
        try withManifestMutation {
            let current = try manifestForCredentialUpdate()
            try saveUnlocked(
                applying(current, anthropicSubscriptionCredentials: .some(credentials)),
                to: settingsURL()
            )
        }
    }

    public static func saveResponseLanguage(_ languageCode: String?) throws {
        try withManifestMutation {
            let current = try manifestForCredentialUpdate()
            try saveUnlocked(
                applying(current, responseLanguage: .some(languageCode)),
                to: settingsURL()
            )
        }
    }

    private static func applying(
        _ current: AgentSettingsManifest,
        selectedModelID: String?? = nil,
        selectedThinkingSelection: AgentThinkingSelection?? = nil,
        chatGPTSubscriptionCredentials: CodexAgentCredentials?? = nil,
        anthropicSubscriptionCredentials: AnthropicSubscriptionCredentials?? = nil,
        responseLanguage: String?? = nil
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            version: current.version,
            providers: current.providers,
            models: current.models,
            selectedModelID: selectedModelID ?? current.selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection ?? current.selectedThinkingSelection,
            telegram: current.telegram,
            voice: current.voice,
            remoteAPIKeysByProviderID: current.remoteAPIKeysByProviderID,
            localExecAllowedCommands: current.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: chatGPTSubscriptionCredentials ?? current.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: anthropicSubscriptionCredentials ?? current.anthropicSubscriptionCredentials,
            responseLanguage: responseLanguage ?? current.responseLanguage,
            memoryEmbedding: current.memoryEmbedding
        )
    }

    private static func manifestForCredentialUpdate() throws -> AgentSettingsManifest {
        do {
            return try loadRequiredUnlocked(from: settingsURL())
        } catch AgentSettingsManifestStoreError.missingFile(_) {
            return AgentSettingsManifest(models: [])
        }
    }

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }
}

public enum AgentSettingsManifestStoreError: LocalizedError {
    case missingFile(URL)
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Missing ZenCODE settings file: \(url.path)"
        case let .unreadableFile(url, error):
            return "Unable to read ZenCODE settings file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid ZenCODE settings file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported ZenCODE settings file \(url.path): version \(found), expected \(expected)"
        }
    }
}
