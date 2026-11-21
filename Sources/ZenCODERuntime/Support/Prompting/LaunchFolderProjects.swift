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
    /// Hidden entries are skipped: dot-names and folders marked hidden by the
    /// file system (the hidden flag on macOS). Regular files and symbolic links
    /// (even to folders; they are never followed) are skipped too. The order is
    /// deterministic and the same on every platform: case-insensitive by name,
    /// with the raw name as tie-break. An unreadable or missing directory yields
    /// an empty list.
    ///
    /// The names of the entries come from `listDirectory` (default
    /// ``defaultListDirectory(atPath:)``), while the type, symbolic-link and
    /// hidden flags of each entry are read from the file system. Tests inject
    /// `listDirectory` to observe when the folder is read.
    public static func scan(
        workingDirectory: URL,
        limit: Int = defaultLimit,
        listDirectory: (String) throws -> [String] = defaultListDirectory
    ) -> LaunchFolderProjects {
        let directory = workingDirectory.standardizedFileURL
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        let entries = (try? listDirectory(directory.path)) ?? []
        let names = entries
            .filter { !$0.hasPrefix(".") }
            .filter { name in
                // No trailing slash: a symbolic link is inspected, not followed.
                let entry = directory.appendingPathComponent(name, isDirectory: false)
                guard let values = try? entry.resourceValues(forKeys: keys) else {
                    return false
                }
                return values.isDirectory == true
                    && values.isSymbolicLink != true
                    && values.isHidden != true
            }
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

    /// Names of the entries at a path, in the order the file system returns
    /// them: the default `listDirectory` of ``scan(workingDirectory:limit:listDirectory:)``.
    public static func defaultListDirectory(atPath path: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path)
    }
}
