//
//  MLXServerHuggingFaceCacheAccess.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import ToolCore
import Foundation
import HuggingFace

public actor MLXServerHuggingFaceCacheAccessStore {
    public static let shared = MLXServerHuggingFaceCacheAccessStore()

    private var activeURL: URL?

    public init() {}

    public nonisolated static var cacheDirectory: URL {
        let settings = MLXServerSettingsStore.loadOrDefault()
        if let configuredPath = settings.huggingFaceCache.directoryPath?.nilIfBlank {
            return normalizedHubCacheDirectory(
                for: URL(fileURLWithPath: configuredPath, isDirectory: true)
            )
        }
        return externalCacheDirectory
    }

    public nonisolated static var cache: HubCache {
        HubCache(cacheDirectory: cacheDirectory)
    }

    public nonisolated static func hubClient() -> HubClient {
        HubClient(cache: cache)
    }

        public nonisolated static var externalCacheDirectory: URL {
        let usersDirectory = FileManager.default.urls(for: .userDirectory, in: .localDomainMask).first
            ?? URL(fileURLWithPath: "/Users", isDirectory: true)
        return usersDirectory
            .appendingPathComponent(NSUserName(), isDirectory: true)
            .appendingPathComponent(".cache", isDirectory: true)
            .appendingPathComponent("huggingface", isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
            .standardizedFileURL
    }

    public nonisolated static func hasReadWriteAccess(
        fileManager: FileManager = .default
    ) -> Bool {
        canReadWriteDirectory(cacheDirectory, fileManager: fileManager)
    }

        public func activatePersistedAccess() -> URL? {
        if let activeURL {
            return activeURL
        }

        let settings = MLXServerSettingsStore.loadOrDefault()
        guard let bookmarkData = settings.huggingFaceCache.bookmarkData else {
            return nil
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            MLXServerSettingsStore.clearHuggingFaceCacheAccess()
            return nil
        }

        let cacheDirectory = Self.cacheDirectory
        let normalizedResolvedURL = Self.normalizedDirectoryURL(resolvedURL)
        guard Self.coversCacheDirectory(
            authorizedDirectoryURL: normalizedResolvedURL,
            cacheDirectoryURL: cacheDirectory
        ) else {
            MLXServerSettingsStore.clearHuggingFaceCacheAccess()
            return nil
        }

        _ = resolvedURL.startAccessingSecurityScopedResource()
        activeURL = resolvedURL

        if isStale {
            try? persistBookmark(
                for: resolvedURL,
                cacheDirectory: cacheDirectory
            )
        }

                return resolvedURL
    }

    public func saveAccess(for selectedURL: URL) throws {
        let cacheDirectory = Self.cacheDirectory
        let normalizedSelectedURL = Self.normalizedDirectoryURL(selectedURL)
        guard Self.coversCacheDirectory(
            authorizedDirectoryURL: normalizedSelectedURL,
            cacheDirectoryURL: cacheDirectory
        ) else {
            throw MLXServerHuggingFaceCacheAccessError.invalidAuthorizedDirectory(
                cacheDirectory.path
            )
        }

        let previousActiveURL = activeURL
        let didStartAccessing = selectedURL.startAccessingSecurityScopedResource()
        do {
            try persistBookmark(
                for: selectedURL,
                cacheDirectory: cacheDirectory
            )
            previousActiveURL?.stopAccessingSecurityScopedResource()
            activeURL = selectedURL
        } catch {
            if didStartAccessing {
                selectedURL.stopAccessingSecurityScopedResource()
            }
                        throw error
        }
    }

    public func clearAccess() {
        activeURL?.stopAccessingSecurityScopedResource()
        activeURL = nil
        MLXServerSettingsStore.clearHuggingFaceCacheAccess()
    }

    private func persistBookmark(
        for directoryURL: URL,
        cacheDirectory: URL
        ) throws {
        let bookmarkData = try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        try MLXServerSettingsStore.saveHuggingFaceCacheAccess(
            cacheDirectoryPath: cacheDirectory.path,
            bookmarkData: bookmarkData
        )
    }

    public nonisolated static func normalizedHubCacheDirectory(for directoryURL: URL) -> URL {
        let standardizedURL = directoryURL.standardizedFileURL.resolvingSymlinksInPath()
        if standardizedURL.lastPathComponent == "hub" {
            return standardizedURL
        }
        if standardizedURL.lastPathComponent == "huggingface" {
            return standardizedURL.appendingPathComponent("hub", isDirectory: true)
        }
        if standardizedURL.path.hasSuffix("/huggingface/hub") {
            return standardizedURL
        }
        return standardizedURL
    }

    public nonisolated static func normalizedDirectoryURL(_ url: URL) -> URL {
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return standardizedURL
        }
        return standardizedURL.hasDirectoryPath
            ? standardizedURL
            : standardizedURL.deletingLastPathComponent()
    }

    public nonisolated static func coversCacheDirectory(
        authorizedDirectoryURL: URL,
        cacheDirectoryURL: URL = cacheDirectory
    ) -> Bool {
        let authorizedPath = normalizedDirectoryURL(authorizedDirectoryURL).path
        let cachePath = normalizedHubCacheDirectory(for: cacheDirectoryURL).path
        let authorizedPrefix = authorizedPath.hasSuffix("/") ? authorizedPath : authorizedPath + "/"
        return cachePath == authorizedPath || cachePath.hasPrefix(authorizedPrefix)
    }

    private nonisolated static func canReadWriteDirectory(
        _ directoryURL: URL,
        fileManager: FileManager
    ) -> Bool {
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            _ = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            let probeURL = directoryURL.appendingPathComponent(
                ".zencode-mlx-access-\(UUID().uuidString)"
            )
            try Data().write(to: probeURL, options: [.atomic])
            try? fileManager.removeItem(at: probeURL)
            return true
        } catch {
            return false
        }
    }
}

public enum MLXServerHuggingFaceCacheAccessError: LocalizedError, Equatable, Sendable {
    case invalidAuthorizedDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAuthorizedDirectory(cachePath):
            return "Selected folder does not grant access to \(cachePath)."
        }
    }
}
