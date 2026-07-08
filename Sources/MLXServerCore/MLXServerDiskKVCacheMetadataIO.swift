//
//  MLXServerDiskKVCacheMetadataIO.swift
//  ZenCODE
//
//  Pure metadata I/O helpers for the disk KV cache. Both the legacy store
//  class and the actor coordinator use these to load, save, and remove
//  persisted session metadata.
//

import Foundation

/// Stateless metadata persistence helpers.
enum MLXServerDiskKVCacheMetadataIO {

    /// Reads and decodes a `MLXServerPersistedChatSessionMetadata` from disk.
    static func loadMetadata(
        from url: URL
    ) -> MLXServerPersistedChatSessionMetadata? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(
            MLXServerPersistedChatSessionMetadata.self,
            from: data
        )
    }

    /// Encodes and writes metadata to the given URL (atomically). When
    /// Encodes and writes metadata to the given URL (atomically).
    static func saveMetadata(
        _ metadata: MLXServerPersistedChatSessionMetadata,
        to url: URL,
        fileManager: FileManager = .default
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    /// Encodes and writes metadata, ensuring the parent directory exists on
    /// first use (tracked via `ensuredDirectoryPaths`).
    static func saveMetadata(
        _ metadata: MLXServerPersistedChatSessionMetadata,
        to url: URL,
        fileManager: FileManager = .default,
        ensuredDirectoryPaths: inout Set<String>
    ) throws {
        try ensureDirectoryExists(
            url.deletingLastPathComponent(),
            fileManager: fileManager,
            ensuredDirectoryPaths: &ensuredDirectoryPaths
        )
        try saveMetadata(metadata, to: url, fileManager: fileManager)
    }

    /// Removes both the cache payload and its associated metadata file.
    static func removeEntry(
        cacheURL: URL,
        metadataURL: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: cacheURL)
        try? fileManager.removeItem(at: metadataURL)
    }

    /// Creates intermediate directories when `path` wasn't already ensured.
    static func ensureDirectoryExists(
        _ url: URL,
        fileManager: FileManager = .default,
        ensuredDirectoryPaths: inout Set<String>
    ) throws {
        let directoryURL = url.standardizedFileURL
        let path = directoryURL.path
        guard !ensuredDirectoryPaths.contains(path) else {
            return
        }
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        ensuredDirectoryPaths.insert(path)
    }
}
