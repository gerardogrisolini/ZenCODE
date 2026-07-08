//
//  MLXServerDiskKVCache.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
//  Orchestrates the disk-backed KV cache: the legacy store class and the
//  actor coordinator both delegate to shared pure components for layout,
//  metadata I/O, and eviction. This file keeps only policy, concurrency
//  serialization, and safetensors loading.
//

import CryptoKit
import Foundation
import os
import MLXLMCommon

public struct MLXServerDiskKVCacheConfiguration: Sendable, Equatable {
    public static let defaultLimitBytes: Int64 = 100 * 1024 * 1024 * 1024

    public var isEnabled: Bool
    public var directory: URL
    public var limitBytes: Int64?

    public init(
        isEnabled: Bool = true,
        directory: URL? = nil,
        limitBytes: Int64? = Self.defaultLimitBytes
    ) {
        self.isEnabled = isEnabled
        self.directory = directory ?? Self.defaultDirectory()
        self.limitBytes = limitBytes
    }

    public static var disabled: Self {
        Self(isEnabled: false, limitBytes: nil)
    }

    public static func defaultDirectory(
        fileManager: FileManager = .default
    ) -> URL {
        MLXServerSettingsStore.supportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("KVCaches", isDirectory: true)
            .standardizedFileURL
    }
}

/// Result of restoring a persisted chat session cache from disk.
/// `@unchecked Sendable`: the loaded `[KVCache]` is freshly deserialized
/// from disk and owned exclusively by the requesting generation task.
struct MLXServerDiskChatSessionMatch: @unchecked Sendable {
    var cache: [KVCache]
    var fingerprints: [MLXServerChatTranscriptFingerprint]
    var matchedPrefixEndIndex: Int
    var contextTokenCount: Int?
}

struct MLXServerPersistedChatSessionMetadata: Codable, Sendable {
    var version: Int
    var sessionKey: String
    var modelID: String
    var runtimeKind: String
    var cacheLayoutSignature: String
    var toolsSignature: String
    var contextSignature: String
    var entryKey: String
    var fingerprints: [MLXServerChatTranscriptFingerprint]
    var contextTokenCount: Int?
    var byteCount: Int64
    var createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date

    func matches(
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String
    ) -> Bool {
        version == MLXServerDiskKVCacheStore.metadataVersion
            && sessionKey == key.sessionKey
            && modelID == key.modelID
            && runtimeKind == key.runtimeKind.rawValue
            && cacheLayoutSignature == key.cacheLayoutSignature
            && entryKey == key.entryKey
            && self.toolsSignature == toolsSignature
            && self.contextSignature == contextSignature
    }
}

struct MLXServerDiskKVCachePersistenceTarget: Sendable {
    var cacheURL: URL
    var metadataURL: URL
    var temporaryURL: URL
}

// MARK: - Legacy store (orchestration)

final class MLXServerDiskKVCacheStore: Sendable {
    static let metadataVersion = 4

    private let configuration: MLXServerDiskKVCacheConfiguration
    private let coordinator: MLXServerDiskKVCacheStoreCoordinator
    private var fileManager: FileManager { .default }

    init(configuration: MLXServerDiskKVCacheConfiguration) {
        self.configuration = configuration
        self.coordinator = MLXServerDiskKVCacheStoreCoordinator(configuration: configuration)
    }

    var isEnabled: Bool {
        configuration.isEnabled
    }

    // MARK: - Load

    /// Restores the persisted cache for a session entry when it can serve
    /// the requested transcript as a strict continuation.
    func loadSession(
        for key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        requestFingerprints: [MLXServerChatTranscriptFingerprint],
        acceptsCompleteMatch: Bool = false
    ) -> MLXServerDiskChatSessionMatch? {
        guard configuration.isEnabled else {
            return nil
        }

        let matchedPrefixEndIndex: Int?
        let urls = MLXServerDiskKVCacheLayout.entryURLs(
            for: key.entryKey,
            modelID: key.modelID,
            directory: configuration.directory
        )
        guard let metadata = MLXServerDiskKVCacheMetadataIO.loadMetadata(from: urls.metadataURL),
              metadata.matches(
                  key: key,
                  toolsSignature: toolsSignature,
                  contextSignature: contextSignature
              ),
              fileManager.fileExists(atPath: urls.cacheURL.path)
        else {
            return nil
        }
        if acceptsCompleteMatch {
            matchedPrefixEndIndex = MLXServerChatSessionTranscript.storedPrefixEndIndex(
                stored: metadata.fingerprints,
                request: requestFingerprints
            )
        } else {
            matchedPrefixEndIndex = MLXServerChatSessionTranscript.continuationSuffixStartIndex(
                stored: metadata.fingerprints,
                request: requestFingerprints
            )
        }
        guard let matchedPrefixEndIndex else {
            return nil
        }

        // Heavy safetensors I/O happens outside the store lock so
        // concurrent lookups and persistence are not serialized behind
        // disk reads.
        do {
            let (cache, _) = try loadPromptCache(url: urls.cacheURL)
            guard cache.hasPromptState else {
                return nil
            }
            return MLXServerDiskChatSessionMatch(
                cache: cache,
                fingerprints: metadata.fingerprints,
                matchedPrefixEndIndex: matchedPrefixEndIndex,
                contextTokenCount: metadata.contextTokenCount ?? cache.contextTokenCount
            )
        } catch {
            return nil
        }
    }

    // MARK: - Persist

    /// Returns false when the entry on disk already represents exactly this
    /// transcript, making a rewrite pointless.
    func needsPersistence(
        for key: MLXServerChatSessionCacheKey,
        fingerprints: [MLXServerChatTranscriptFingerprint]
    ) -> Bool {
        guard configuration.isEnabled else {
            return false
        }
        let urls = MLXServerDiskKVCacheLayout.entryURLs(
            for: key.entryKey,
            modelID: key.modelID,
            directory: configuration.directory
        )
        guard let metadata = MLXServerDiskKVCacheMetadataIO.loadMetadata(from: urls.metadataURL),
              metadata.entryKey == key.entryKey,
              fileManager.fileExists(atPath: urls.cacheURL.path) else {
            return true
        }
        return metadata.fingerprints != fingerprints
    }

    func preparePersistenceTarget(
        for key: MLXServerChatSessionCacheKey
    ) async throws -> MLXServerDiskKVCachePersistenceTarget? {
        try await coordinator.preparePersistenceTarget(for: key)
    }

    func commitPersistedSession(
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        contextTokenCount: Int? = nil,
        target: MLXServerDiskKVCachePersistenceTarget
    ) async throws {
        try await coordinator.commitPersistedSession(
            key: key,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            fingerprints: fingerprints,
            contextTokenCount: contextTokenCount,
            target: target
        )
    }

    func discardPersistenceTarget(_ target: MLXServerDiskKVCachePersistenceTarget) async {
        await coordinator.discardPersistenceTarget(target)
    }

    func enforceDiskLimit() async {
        await coordinator.enforceDiskLimit()
    }
}

// MARK: - Actor coordinator (concurrency serialization)

private actor MLXServerDiskKVCacheStoreCoordinator {
    private let configuration: MLXServerDiskKVCacheConfiguration
    private var ensuredDirectoryPaths: Set<String> = []
    private var fileManager: FileManager { .default }

    init(configuration: MLXServerDiskKVCacheConfiguration) {
        self.configuration = configuration
    }

    func preparePersistenceTarget(
        for key: MLXServerChatSessionCacheKey
    ) throws -> MLXServerDiskKVCachePersistenceTarget? {
        guard configuration.isEnabled else {
            return nil
        }
        let urls = MLXServerDiskKVCacheLayout.entryURLs(
            for: key.entryKey,
            modelID: key.modelID,
            directory: configuration.directory
        )
        let temporaryURL = urls.cacheURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(key.entryKey).\(UUID().uuidString).tmp.safetensors"
            )

        try MLXServerDiskKVCacheMetadataIO.ensureDirectoryExists(
            urls.cacheURL.deletingLastPathComponent(),
            fileManager: fileManager,
            ensuredDirectoryPaths: &ensuredDirectoryPaths
        )

        return MLXServerDiskKVCachePersistenceTarget(
            cacheURL: urls.cacheURL,
            metadataURL: urls.metadataURL,
            temporaryURL: temporaryURL
        )
    }

    func commitPersistedSession(
        key: MLXServerChatSessionCacheKey,
        toolsSignature: String,
        contextSignature: String,
        fingerprints: [MLXServerChatTranscriptFingerprint],
        contextTokenCount: Int? = nil,
        target: MLXServerDiskKVCachePersistenceTarget
    ) throws {
        if fileManager.fileExists(atPath: target.cacheURL.path) {
            _ = try fileManager.replaceItemAt(target.cacheURL, withItemAt: target.temporaryURL)
        } else {
            try fileManager.moveItem(at: target.temporaryURL, to: target.cacheURL)
        }

        let now = Date()
        let existingMetadata = MLXServerDiskKVCacheMetadataIO.loadMetadata(
            from: target.metadataURL
        )
        let metadata = MLXServerPersistedChatSessionMetadata(
            version: MLXServerDiskKVCacheStore.metadataVersion,
            sessionKey: key.sessionKey,
            modelID: key.modelID,
            runtimeKind: key.runtimeKind.rawValue,
            cacheLayoutSignature: key.cacheLayoutSignature,
            toolsSignature: toolsSignature,
            contextSignature: contextSignature,
            entryKey: key.entryKey,
            fingerprints: fingerprints,
            contextTokenCount: contextTokenCount,
            byteCount: MLXServerDiskKVCacheLayout.byteCount(
                of: target.cacheURL,
                fileManager: fileManager
            ),
            createdAt: existingMetadata?.createdAt ?? now,
            updatedAt: now,
            lastAccessedAt: now
        )
        do {
            try MLXServerDiskKVCacheMetadataIO.saveMetadata(
                metadata,
                to: target.metadataURL,
                fileManager: fileManager,
                ensuredDirectoryPaths: &ensuredDirectoryPaths
            )
        } catch {
            try? fileManager.removeItem(at: target.cacheURL)
            try? fileManager.removeItem(at: target.metadataURL)
            throw error
        }
        enforceDiskLimit(preserving: target.cacheURL)
    }

    func discardPersistenceTarget(_ target: MLXServerDiskKVCachePersistenceTarget) {
        try? fileManager.removeItem(at: target.temporaryURL)
    }

    func enforceDiskLimit() {
        enforceDiskLimit(preserving: nil)
    }

    private func enforceDiskLimit(preserving preservedCacheURL: URL?) {
        MLXServerDiskKVCacheEvictor.enforceDiskLimit(
            preserving: preservedCacheURL,
            configuration: configuration,
            metadataVersion: MLXServerDiskKVCacheStore.metadataVersion,
            fileManager: fileManager
        )
    }
}

extension Array where Element == KVCache {
    var hasPromptState: Bool {
        let state = flatMap(\.state)
        return !state.isEmpty && state.allSatisfy { $0.size > 0 }
    }

    var contextTokenCount: Int? {
        let offsets = map(\.offset).filter { $0 > 0 }
        return offsets.max()
    }
}
