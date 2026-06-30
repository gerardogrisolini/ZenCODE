//
//  MLXServerModelSetupRunner+CacheScanner.swift
//  ZenCODE
//

import Foundation
import HuggingFace
import MLXServerCore

enum MLXServerCachedModelScanner {
    static func candidates(
        cache: HubCache = MLXServerHuggingFaceCacheAccessStore.cache,
        fileManager: FileManager = .default
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryDirectories = try? fileManager.contentsOfDirectory(
            at: cache.cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return repositoryDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .flatMap { repositoryDirectory in
                candidates(
                    in: repositoryDirectory,
                    fileManager: fileManager
                )
            }
            .sorted {
                let repositoryOrder = $0.repositoryID.localizedStandardCompare($1.repositoryID)
                if repositoryOrder != .orderedSame {
                    return repositoryOrder == .orderedAscending
                }
                return $0.revision.localizedStandardCompare($1.revision) == .orderedAscending
            }
    }

    private static func candidates(
        in repositoryDirectory: URL,
        fileManager: FileManager
    ) -> [MLXServerCachedModelCandidate] {
        guard let repositoryID = repositoryID(fromCacheDirectoryName: repositoryDirectory.lastPathComponent) else {
            return []
        }

        let snapshotsDirectory = repositoryDirectory.appendingPathComponent("snapshots", isDirectory: true)
        guard let snapshotDirectories = try? fileManager.contentsOfDirectory(
            at: snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return snapshotDirectories
            .filter { isDirectory($0, fileManager: fileManager) }
            .filter { isUsableSnapshot($0, fileManager: fileManager) }
            .map {
                MLXServerCachedModelCandidate(
                    repositoryID: repositoryID,
                    revision: $0.lastPathComponent,
                    snapshotURL: $0
                )
            }
    }

    private static func repositoryID(fromCacheDirectoryName name: String) -> String? {
        guard name.hasPrefix("models--") else {
            return nil
        }

        let encodedRepositoryID = String(name.dropFirst("models--".count))
        let components = encodedRepositoryID.split(separator: "--", omittingEmptySubsequences: false)
        guard components.count >= 2 else {
            return nil
        }

        let namespace = components[0]
        let repositoryName = components.dropFirst().joined(separator: "--")
        guard !namespace.isEmpty, !repositoryName.isEmpty else {
            return nil
        }
        return "\(namespace)/\(repositoryName)"
    }

    private static func isUsableSnapshot(
        _ snapshotURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(
            atPath: snapshotURL.appendingPathComponent("config.json").path
        ) else {
            return false
        }

        guard let enumerator = fileManager.enumerator(
            at: snapshotURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent.lowercased()
            if filename.hasSuffix(".safetensors")
                || filename.hasSuffix(".gguf")
                || filename == "model.safetensors.index.json" {
                return true
            }
        }
        return false
    }

    private static func isDirectory(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

