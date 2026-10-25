//
//  LaunchFolderProjects.swift
//  ZenCODE
//

import Foundation

/// Snapshot of the folders directly inside an agent's working (launch)
/// directory.
///
/// A coordinator that delegates by role (see
/// ``AgentProfileRole/delegatesByRole``) works on projects that live in
/// sibling folders of its launch directory. The snapshot is taken once, when
/// the agent is selected, and is never refreshed while the session lives:
/// callers own the lifetime of the value they pass to the prompt builders.
public struct LaunchFolderProjects: Sendable, Equatable {
    /// Maximum number of folder names listed; the rest are only counted.
    public static let defaultLimit = 100

    /// Standardized path of the directory that was read.
    public let workingDirectoryPath: String
    /// Names of the first-level, non-hidden folders, sorted case-insensitively
    /// and capped to the scan limit.
    public let folderNames: [String]
    /// Number of further folders that were found but are not in
    /// ``folderNames``.
    public let omittedCount: Int

    public init(
        workingDirectoryPath: String,
        folderNames: [String],
        omittedCount: Int
    ) {
        self.workingDirectoryPath = workingDirectoryPath
        self.folderNames = folderNames
        self.omittedCount = omittedCount
    }

    /// Reads the first-level, non-hidden subfolders of `workingDirectory`.
    ///
    /// Hidden entries, regular files, and symbolic links (even to folders; they
    /// are never followed) are skipped. The order is deterministic and the
    /// same on every platform: case-insensitive by name, with the raw name as
    /// tie-break. An unreadable or missing directory yields an empty list.
    public static func scan(
        workingDirectory: URL,
        fileManager: FileManager = .default,
        limit: Int = defaultLimit
    ) -> LaunchFolderProjects {
        let directory = workingDirectory.standardizedFileURL
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []
        let names = entries
            .filter { entry in
                // `skipsHiddenFiles` does not cover dot-names on every platform.
                guard !entry.lastPathComponent.hasPrefix(".") else {
                    return false
                }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                return values?.isDirectory == true && values?.isSymbolicLink != true
            }
            .map(\.lastPathComponent)
            .sorted { lhs, rhs in
                let lhsKey = lhs.lowercased()
                let rhsKey = rhs.lowercased()
                return lhsKey == rhsKey ? lhs < rhs : lhsKey < rhsKey
            }
        let kept = max(limit, 0)
        return LaunchFolderProjects(
            workingDirectoryPath: directory.path,
            folderNames: Array(names.prefix(kept)),
            omittedCount: max(names.count - kept, 0)
        )
    }
}
