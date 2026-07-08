//
//  MLXServerDiskKVCacheEvictor.swift
//  ZenCODE
//
//  Pure disk enumeration, orphan cleanup, and LRU eviction logic. Both the
//  legacy store class and the actor coordinator reuse this code so that
//  eviction policies are defined once.
//

import Foundation

/// Stateless eviction and enumeration helpers.
enum MLXServerDiskKVCacheEvictor {

    // MARK: - Types

    public struct PersistedEntry {
        public var metadataURL: URL
        public var cacheURL: URL
        public var metadata: MLXServerPersistedChatSessionMetadata

        public init(
            metadataURL: URL,
            cacheURL: URL,
            metadata: MLXServerPersistedChatSessionMetadata
        ) {
            self.metadataURL = metadataURL
            self.cacheURL = cacheURL
            self.metadata = metadata
        }
    }

    // MARK: - Constants

    /// Temporary persistence files older than this are considered leftovers
    /// from a crashed or interrupted write and are removed while enumerating.
    static let orphanedTemporaryFileMaxAge: TimeInterval = 60 * 60

    // MARK: - Enumeration

    /// Scans the cache directory and returns all valid persisted entries,
    /// cleaning up stale or orphaned files as a side effect.
    static func persistedEntriesFromDisk(
        configuration: MLXServerDiskKVCacheConfiguration,
        metadataVersion: Int,
        fileManager: FileManager = .default
    ) -> [PersistedEntry] {
        guard
            fileManager.fileExists(atPath: configuration.directory.path),
            let enumerator = fileManager.enumerator(
                at: configuration.directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        var entries: [PersistedEntry] = []
        var cacheFileURLs: [URL] = []
        var referencedCachePaths = Set<String>()
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "safetensors" {
                cacheFileURLs.append(url)
                continue
            }
            guard url.pathExtension == "json",
                  var metadata = MLXServerDiskKVCacheMetadataIO.loadMetadata(from: url) else {
                continue
            }

            let cacheURL = url.deletingPathExtension().appendingPathExtension("safetensors")
            guard metadata.version == metadataVersion else {
                MLXServerDiskKVCacheMetadataIO.removeEntry(
                    cacheURL: cacheURL,
                    metadataURL: url,
                    fileManager: fileManager
                )
                continue
            }

            guard fileManager.fileExists(atPath: cacheURL.path) else {
                try? fileManager.removeItem(at: url)
                continue
            }

            referencedCachePaths.insert(cacheURL.standardizedFileURL.path)
            let currentByteCount = MLXServerDiskKVCacheLayout.byteCount(
                of: cacheURL,
                fileManager: fileManager
            )
            if metadata.byteCount != currentByteCount {
                metadata.byteCount = currentByteCount
                try? MLXServerDiskKVCacheMetadataIO.saveMetadata(
                    metadata,
                    to: url,
                    fileManager: fileManager
                )
            }
            entries.append(
                PersistedEntry(
                    metadataURL: url,
                    cacheURL: cacheURL,
                    metadata: metadata
                )
            )
        }

        removeOrphanedCacheFiles(
            cacheFileURLs,
            referencedCachePaths: referencedCachePaths,
            fileManager: fileManager
        )
        return entries
    }

    // MARK: - Orphan cleanup

    /// Deletes cache payloads that no metadata references: `.safetensors`
    /// files left behind by a crash between move and metadata write, and
    /// stale `.tmp.safetensors` files from interrupted writes.
    static func removeOrphanedCacheFiles(
        _ cacheFileURLs: [URL],
        referencedCachePaths: Set<String>,
        fileManager: FileManager = .default
    ) {
        for url in cacheFileURLs {
            let standardizedURL = url.standardizedFileURL
            if standardizedURL.deletingPathExtension().pathExtension == "tmp" {
                let modificationDate =
                    (try? fileManager.attributesOfItem(atPath: standardizedURL.path))?[
                        .modificationDate
                    ] as? Date
                let age = Date().timeIntervalSince(modificationDate ?? .distantPast)
                if age > orphanedTemporaryFileMaxAge {
                    try? fileManager.removeItem(at: standardizedURL)
                }
                continue
            }
            if !referencedCachePaths.contains(standardizedURL.path) {
                try? fileManager.removeItem(at: standardizedURL)
            }
        }
    }

    // MARK: - Eviction

    /// Enforces the configured byte limit by removing the least-recently-used
    /// entries, optionally preserving a specific cache URL.
    static func enforceDiskLimit(
        preserving preservedCacheURL: URL?,
        configuration: MLXServerDiskKVCacheConfiguration,
        metadataVersion: Int,
        fileManager: FileManager = .default
    ) {
        guard let limitBytes = configuration.limitBytes, limitBytes > 0 else {
            return
        }

        let entries = persistedEntriesFromDisk(
            configuration: configuration,
            metadataVersion: metadataVersion,
            fileManager: fileManager
        )
        let totalByteCount = entries.reduce(Int64(0)) { partial, entry in
            partial + max(entry.metadata.byteCount, 0)
        }
        guard totalByteCount > limitBytes else {
            return
        }

        let targetByteCount = max(Int64(0), limitBytes * 4 / 5)
        var runningByteCount = totalByteCount
        let evictionCandidates = entries
            .filter { entry in
                guard let preservedCacheURL else {
                    return true
                }
                return entry.cacheURL.standardizedFileURL != preservedCacheURL.standardizedFileURL
            }
            .sorted { lhs, rhs in
                if lhs.metadata.lastAccessedAt != rhs.metadata.lastAccessedAt {
                    return lhs.metadata.lastAccessedAt < rhs.metadata.lastAccessedAt
                }
                if lhs.metadata.updatedAt != rhs.metadata.updatedAt {
                    return lhs.metadata.updatedAt < rhs.metadata.updatedAt
                }
                return lhs.metadata.entryKey < rhs.metadata.entryKey
            }

        for entry in evictionCandidates where runningByteCount > targetByteCount {
            runningByteCount -= max(entry.metadata.byteCount, 0)
            MLXServerDiskKVCacheMetadataIO.removeEntry(
                cacheURL: entry.cacheURL,
                metadataURL: entry.metadataURL,
                fileManager: fileManager
            )
        }
    }
}
