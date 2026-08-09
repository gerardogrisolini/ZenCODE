//
//  MemoryGraphLocation.swift
//  ZenCODE
//
//  Resolves where a workspace's MemoryEngine graph is persisted.
//

import Crypto
import Foundation

/// Resolves the on-disk location of the per-workspace memory graph.
///
/// The graph is a machine-readable blob (it embeds float vectors), so it is
/// deliberately kept out of the workspace working tree and stored beside the
/// other ZenCODE state in the support directory. This honours
/// `ZENCODE_SUPPORT_DIRECTORY` and the `~/.zencode` default, including the
/// task-local override used by tests.
enum MemoryGraphLocation {
    static let directoryName = "memory"
    static let graphFilename = "memory.graph.json"

    /// Full SHA256 hex of the standardized workspace path.
    ///
    /// A full 32-byte digest is used here rather than the 16-byte UUID form of
    /// `LegacyMemoryJournal.legacyIdentifier`, because this value names a
    /// directory shared by every workspace on the machine.
    static func workspaceDigest(for workspaceRootURL: URL) -> String {
        let path = workspaceRootURL.standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func graphDirectoryURL(
        for workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(workspaceDigest(for: workspaceRootURL), isDirectory: true)
    }

    static func graphURL(
        for workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        graphDirectoryURL(for: workspaceRootURL, fileManager: fileManager)
            .appendingPathComponent(graphFilename, isDirectory: false)
            .standardizedFileURL
    }

    /// Legacy human-readable journal that seeds the graph on first open.
    static func legacyJournalURL(for workspaceRootURL: URL) -> URL {
        workspaceRootURL.standardizedFileURL
            .appendingPathComponent(MemoryService.filename)
    }
}
