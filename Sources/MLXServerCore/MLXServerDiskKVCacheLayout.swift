//
//  MLXServerDiskKVCacheLayout.swift
//  ZenCODE
//
//  Pure file-system layout helpers for the disk KV cache. Both the legacy
//  store class and the actor coordinator use these so that URL derivation,
//  model-directory hashing, and byte counting are defined once.
//

import CryptoKit
import Foundation

/// Stateless helpers for disk KV cache file layout.
enum MLXServerDiskKVCacheLayout {

    /// Returns the `.safetensors` and `.json` URLs for a given entry.
    static func entryURLs(
        for entryKey: String,
        modelID: String,
        directory: URL
    ) -> (cacheURL: URL, metadataURL: URL) {
        let modelDirectory = directory
            .appendingPathComponent(modelDirectoryName(modelID), isDirectory: true)
        let baseURL = modelDirectory.appendingPathComponent(entryKey)
        return (
            cacheURL: baseURL.appendingPathExtension("safetensors"),
            metadataURL: baseURL.appendingPathExtension("json")
        )
    }

    /// Hashed directory name scoped to a model identifier.
    static func modelDirectoryName(_ modelID: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(modelID.utf8))
        return String(SHA256.hexString(from: hasher.finalize()).prefix(32))
    }

    /// Size of a file in bytes, or 0 when unavailable.
    static func byteCount(
        of url: URL,
        fileManager: FileManager = .default
    ) -> Int64 {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
