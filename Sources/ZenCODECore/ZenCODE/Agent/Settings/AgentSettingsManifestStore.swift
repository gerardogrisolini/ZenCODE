//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

public enum AgentSettingsManifestStore {
    public static let settingsFilename = "settings.json"
    private static let defaultSettingsCache = DefaultSettingsCache()

    public static func load() -> AgentSettingsManifest? {
        try? loadRequired()
    }

    public static func preload() {
        _ = load()
    }

    #if DEBUG
    static func resetDefaultCacheForTesting() {
        defaultSettingsCache.reset()
    }
    #endif

    public static func loadRequired() throws -> AgentSettingsManifest {
        try defaultSettingsCache.load {
            try loadRequired(from: settingsURL())
        }
    }

    public static func loadRequired(
        from url: URL
    ) throws -> AgentSettingsManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentSettingsManifestStoreError.missingFile(url)
        }

        let data: Data
        do {
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
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
        if url.standardizedFileURL.path == settingsURL().standardizedFileURL.path {
            defaultSettingsCache.store(manifest)
        }
    }

    public static func saveSelectedModel(
        modelID: String,
        thinkingSelection: AgentThinkingSelection?
    ) throws {
        let current = try loadRequired(from: settingsURL())
        try save(
            AgentSettingsManifest(
                version: current.version,
                providers: current.providers,
                models: current.models,
                selectedModelID: modelID,
                selectedThinkingSelection: thinkingSelection,
                telegram: current.telegram,
                voice: current.voice,
                remoteAPIKeysByProviderID: current.remoteAPIKeysByProviderID,
                localExecAllowedCommands: current.localExecAllowedCommands,
                chatGPTSubscriptionCredentials: current.chatGPTSubscriptionCredentials,
                anthropicSubscriptionCredentials: current.anthropicSubscriptionCredentials
            )
        )
    }

    public static func saveSelectedThinkingSelection(
        _ thinkingSelection: AgentThinkingSelection?
    ) throws {
        let current = try loadRequired(from: settingsURL())
        try save(
            AgentSettingsManifest(
                version: current.version,
                providers: current.providers,
                models: current.models,
                selectedModelID: current.selectedModelID,
                selectedThinkingSelection: thinkingSelection,
                telegram: current.telegram,
                voice: current.voice,
                remoteAPIKeysByProviderID: current.remoteAPIKeysByProviderID,
                localExecAllowedCommands: current.localExecAllowedCommands,
                chatGPTSubscriptionCredentials: current.chatGPTSubscriptionCredentials,
                anthropicSubscriptionCredentials: current.anthropicSubscriptionCredentials
            )
        )
    }

    public static func saveChatGPTSubscriptionCredentials(
        _ credentials: CodexAgentCredentials?
    ) throws {
        let current = try manifestForCredentialUpdate()
        try save(
            AgentSettingsManifest(
                version: current.version,
                providers: current.providers,
                models: current.models,
                selectedModelID: current.selectedModelID,
                selectedThinkingSelection: current.selectedThinkingSelection,
                telegram: current.telegram,
                voice: current.voice,
                remoteAPIKeysByProviderID: current.remoteAPIKeysByProviderID,
                localExecAllowedCommands: current.localExecAllowedCommands,
                chatGPTSubscriptionCredentials: credentials,
                anthropicSubscriptionCredentials: current.anthropicSubscriptionCredentials
            )
        )
    }

    public static func saveAnthropicSubscriptionCredentials(
        _ credentials: AnthropicSubscriptionCredentials?
    ) throws {
        let current = try manifestForCredentialUpdate()
        try save(
            AgentSettingsManifest(
                version: current.version,
                providers: current.providers,
                models: current.models,
                selectedModelID: current.selectedModelID,
                selectedThinkingSelection: current.selectedThinkingSelection,
                telegram: current.telegram,
                voice: current.voice,
                remoteAPIKeysByProviderID: current.remoteAPIKeysByProviderID,
                localExecAllowedCommands: current.localExecAllowedCommands,
                chatGPTSubscriptionCredentials: current.chatGPTSubscriptionCredentials,
                anthropicSubscriptionCredentials: credentials
            )
        )
    }

    private static func manifestForCredentialUpdate() throws -> AgentSettingsManifest {
        do {
            return try loadRequired(from: settingsURL())
        } catch AgentSettingsManifestStoreError.missingFile(_) {
            return AgentSettingsManifest(models: [])
        }
    }

    public static func settingsURL(fileManager: FileManager = .default) -> URL {
        MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    private final class DefaultSettingsCache: Sendable {
        private enum State {
            case notLoaded
            case loaded(AgentSettingsManifest)
            case failed(Error)
        }

        private let state = OSAllocatedUnfairLock(initialState: State.notLoaded)

        func load(
            _ loader: @Sendable () throws -> AgentSettingsManifest
        ) throws -> AgentSettingsManifest {
            try state.withLock { state in
                switch state {
                case let .loaded(manifest):
                    return manifest
                case let .failed(error):
                    throw error
                case .notLoaded:
                    break
                }

                do {
                    let manifest = try loader()
                    state = .loaded(manifest)
                    return manifest
                } catch {
                    if case AgentSettingsManifestStoreError.missingFile = error {
                        state = .notLoaded
                    } else {
                        state = .failed(error)
                    }
                    throw error
                }
            }
        }

        func store(_ manifest: AgentSettingsManifest) {
            state.withLock { state in
                state = .loaded(manifest)
            }
        }

        #if DEBUG
        func reset() {
            state.withLock { state in
                state = .notLoaded
            }
        }
        #endif
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
