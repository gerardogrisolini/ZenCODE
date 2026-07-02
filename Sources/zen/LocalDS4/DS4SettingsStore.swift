//
//  DS4SettingsStore.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

struct DS4SettingsManifest: Codable, Equatable {
    static let currentVersion = 1
    static let minimumSupportedVersion = 1

    var version: Int
    var ds4Root: String
    var libraryPath: String?
    var modelPath: String?
    var backend: String?
    var contextWindow: Int?
    var nThreads: Int?
    var prefillChunk: UInt32?
    var maxToolRounds: Int?
    var maxOutputTokens: Int?
    var mtpPath: String?
    var mtpDraftTokens: Int?
    var mtpMargin: Float?
    var powerPercent: Int?
    var ssdStreaming: Bool?
    var ssdStreamingCold: Bool?
    var ssdStreamingCacheExperts: UInt32?
    var ssdStreamingCacheBytes: UInt64?
    var ssdStreamingPreloadExperts: UInt32?
    var quality: Bool?
    var temperature: Float?
    var topK: Int?
    var topP: Float?
    var minP: Float?
    var seed: UInt64?

    init(
        version: Int = Self.currentVersion,
        ds4Root: String,
        libraryPath: String? = nil,
        modelPath: String? = nil,
        backend: String? = nil,
        contextWindow: Int? = nil,
        nThreads: Int? = nil,
        prefillChunk: UInt32? = nil,
        maxToolRounds: Int? = nil,
        maxOutputTokens: Int? = nil,
        mtpPath: String? = nil,
        mtpDraftTokens: Int? = nil,
        mtpMargin: Float? = nil,
        powerPercent: Int? = nil,
        ssdStreaming: Bool? = nil,
        ssdStreamingCold: Bool? = nil,
        ssdStreamingCacheExperts: UInt32? = nil,
        ssdStreamingCacheBytes: UInt64? = nil,
        ssdStreamingPreloadExperts: UInt32? = nil,
        quality: Bool? = nil,
        temperature: Float? = nil,
        topK: Int? = nil,
        topP: Float? = nil,
        minP: Float? = nil,
        seed: UInt64? = nil
    ) {
        self.version = version
        self.ds4Root = ds4Root
        self.libraryPath = libraryPath
        self.modelPath = modelPath
        self.backend = backend
        self.contextWindow = contextWindow
        self.nThreads = nThreads
        self.prefillChunk = prefillChunk
        self.maxToolRounds = maxToolRounds
        self.maxOutputTokens = maxOutputTokens
        self.mtpPath = mtpPath
        self.mtpDraftTokens = mtpDraftTokens
        self.mtpMargin = mtpMargin
        self.powerPercent = powerPercent
        self.ssdStreaming = ssdStreaming
        self.ssdStreamingCold = ssdStreamingCold
        self.ssdStreamingCacheExperts = ssdStreamingCacheExperts
        self.ssdStreamingCacheBytes = ssdStreamingCacheBytes
        self.ssdStreamingPreloadExperts = ssdStreamingPreloadExperts
        self.quality = quality
        self.temperature = temperature
        self.topK = topK
        self.topP = topP
        self.minP = minP
        self.seed = seed
    }
}

enum DS4SettingsStore {
    static let settingsFilename = "settings.json"

    static func load(fileManager: FileManager = .default) throws -> DS4SettingsManifest? {
        let url = settingsURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try loadRequired(from: url)
    }

    static func loadRequired(from url: URL = settingsURL()) throws -> DS4SettingsManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DS4SettingsStoreError.unreadableFile(url, error)
        }

        let manifest: DS4SettingsManifest
        do {
            manifest = try JSONDecoder().decode(DS4SettingsManifest.self, from: data)
        } catch {
            throw DS4SettingsStoreError.invalidFile(url, error)
        }

        guard manifest.version >= DS4SettingsManifest.minimumSupportedVersion,
              manifest.version <= DS4SettingsManifest.currentVersion else {
            throw DS4SettingsStoreError.unsupportedVersion(
                url,
                manifest.version,
                DS4SettingsManifest.currentVersion
            )
        }

        return manifest
    }

    static func save(
        _ manifest: DS4SettingsManifest,
        to url: URL = settingsURL(),
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: url, options: [.atomic])
    }

    static func settingsURL(fileManager: FileManager = .default) -> URL {
        settingsDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(settingsFilename)
            .standardizedFileURL
    }

    static func settingsDirectoryURL(fileManager: FileManager = .default) -> URL {
        MLXAppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("ds4", isDirectory: true)
            .standardizedFileURL
    }
}

enum DS4SettingsStoreError: LocalizedError {
    case unreadableFile(URL, Error)
    case invalidFile(URL, Error)
    case unsupportedVersion(URL, Int, Int)

    var errorDescription: String? {
        switch self {
        case let .unreadableFile(url, error):
            return "Unable to read DS4 settings file \(url.path): \(error.localizedDescription)"
        case let .invalidFile(url, error):
            return "Invalid DS4 settings file \(url.path): \(error.localizedDescription)"
        case let .unsupportedVersion(url, found, expected):
            return "Unsupported DS4 settings file \(url.path): version \(found), expected \(expected)"
        }
    }
}

enum DS4ModelDiscovery {
    static func ggufModelCandidates(in ds4Root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: ds4Root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidatesByPath: [String: URL] = [:]
        for case let url as URL in enumerator {
            guard isGGUFModelFile(url) else {
                continue
            }
            let standardizedURL = url.standardizedFileURL
            candidatesByPath[standardizedURL.path] = standardizedURL
        }

        return candidatesByPath.values.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    static func isGGUFModelFile(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "gguf" && isFile(url)
    }

    static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}
