//
//  MemoryGraphLocation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Resolves where a workspace's MemoryEngine graph is persisted.
//

import Foundation

/// Resolves the on-disk location of the per-workspace and global memory graphs.
///
/// The graph is a machine-readable blob (it embeds float vectors), so it is
/// deliberately kept out of the workspace working tree and stored beside the
/// other ZenCODE state in the support directory. This honours
/// `ZENCODE_SUPPORT_DIRECTORY` and the `~/.zencode` default, including the
/// task-local override used by tests.
enum MemoryGraphLocation {
    static let directoryName = "memory"
    static let graphFilename = "memory.graph.json"
    /// Directory of the global graph. It cannot collide with a workspace
    /// directory, which is always named after a 64-character SHA256 hex digest.
    static let globalDirectoryName = "global"

    /// Full SHA256 hex of the standardized workspace path.
    ///
    /// The full digest names a directory shared by every workspace on the machine.
    static func workspaceDigest(for workspaceRootURL: URL) -> String {
        let path = workspaceRootURL.standardizedFileURL.path
        return Data(path.utf8).sha256Hex()
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

    /// `<support>/memory/global/memory.graph.json`, independent of any workspace.
    static func globalGraphURL(fileManager: FileManager = .default) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(globalDirectoryName, isDirectory: true)
            .appendingPathComponent(graphFilename, isDirectory: false)
            .standardizedFileURL
    }

    static func graphURL(
        for target: MemoryGraphTarget,
        fileManager: FileManager = .default
    ) -> URL {
        switch target {
        case .workspace(let workspaceRootURL):
            graphURL(for: workspaceRootURL, fileManager: fileManager)
        case .global:
            globalGraphURL(fileManager: fileManager)
        }
    }
}
