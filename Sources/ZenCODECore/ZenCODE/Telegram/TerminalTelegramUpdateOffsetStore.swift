//
//  TerminalTelegramUpdateOffsetStore.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Durable, per-bot high-water marks for Telegram long polling.
///
/// The offset is published before an update reaches the prompt mailbox. This
/// deliberately provides at-most-once delivery across crashes: replaying a
/// destructive prompt is less safe than dropping the single update interrupted
/// between offset publication and local handling.
enum TerminalTelegramUpdateOffsetStore {
    private static let mutationLock = Mutex<Void>(())

    private struct Manifest: Codable {
        var version = 1
        var updateIDsByBotID: [String: Int] = [:]
    }

    private static let filename = "telegram-updates.json"

    static func load(
        botID: Int64,
        from url: URL = defaultURL(),
        fileManager: FileManager = .default
    ) -> Int? {
        try? loadRequired(botID: botID, from: url, fileManager: fileManager)
    }

    static func loadRequired(
        botID: Int64,
        from url: URL = defaultURL(),
        fileManager: FileManager = .default
    ) throws -> Int? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try mutationLock.withLock { _ in
            try SensitiveManifestCoordination.withExclusiveLock(
                supportDirectoryURL: url.deletingLastPathComponent()
            ) {
                try SensitiveFilePermissions.hardenExistingFile(at: url, fileManager: fileManager)
                let data = try Data(contentsOf: url)
                let manifest = try JSONDecoder().decode(Manifest.self, from: data)
                guard manifest.version == 1 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return manifest.updateIDsByBotID[String(botID)]
            }
        }
    }

    static func save(
        updateID: Int,
        botID: Int64,
        to url: URL = defaultURL(),
        fileManager: FileManager = .default
    ) throws {
        try mutationLock.withLock { _ in
            try SensitiveManifestCoordination.withExclusiveLock(
                supportDirectoryURL: url.deletingLastPathComponent()
            ) {
                var manifest = Manifest()
                if fileManager.fileExists(atPath: url.path) {
                    try SensitiveFilePermissions.hardenExistingFile(at: url, fileManager: fileManager)
                    let data = try Data(contentsOf: url)
                    manifest = try JSONDecoder().decode(Manifest.self, from: data)
                    guard manifest.version == 1 else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                }
                let key = String(botID)
                manifest.updateIDsByBotID[key] = max(
                    updateID,
                    manifest.updateIDsByBotID[key] ?? updateID
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try SensitiveFilePermissions.write(
                    encoder.encode(manifest),
                    to: url,
                    fileManager: fileManager
                )
            }
        }
    }

    private static func defaultURL() -> URL {
        AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent(filename, isDirectory: false)
    }
}
