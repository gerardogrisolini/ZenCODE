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
    /// directory, whose name (``ProjectStorageKey``) always contains a `-`.
    static let globalDirectoryName = "global"

    /// A workspace graph lives under the project's name-based key, so it
    /// follows a project whose folder is moved.
    static func graphDirectoryURL(
        for workspaceRootURL: URL,
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(ProjectStorageKey.key(for: workspaceRootURL), isDirectory: true)
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
