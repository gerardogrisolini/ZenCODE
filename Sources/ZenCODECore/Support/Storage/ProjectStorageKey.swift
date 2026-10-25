//
//  ProjectStorageKey.swift
//  ZenCODE
//
//  Name-based identity of a project in the support directory, shared by the
//  per-project stores.
//

import Foundation

/// Identifies a project in the support directory by its name — the name of
/// the project folder — rather than by its full path, so the project memory,
/// the project agents, the saved sessions and the task graphs follow a project
/// whose folder is moved. Two folders with the same name are the same project
/// and share that data by design.
///
/// The persisted directory name is `<stem>-<first 24 hex of SHA256(name)>`:
/// a readable, filesystem-safe stem of the name plus a digest of the exact
/// name. It always contains a `-`, so it never collides with the `global`
/// memory directory.
public enum ProjectStorageKey {
    static let hashLength = 24
    static let maximumStemLength = 64

    /// The project name: the last component of the standardized path, trimmed
    /// and in precomposed (NFC) form, compared case-sensitively. A path
    /// without a usable last component (the filesystem root) is its own name.
    public static func projectName(for workspaceRootURL: URL) -> String {
        let standardized = workspaceRootURL.standardizedFileURL
        let component = standardized.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !component.isEmpty, component != "/" else {
            return standardized.path.precomposedStringWithCanonicalMapping
        }
        return component
    }

    public static func projectName(forPath path: String) -> String {
        projectName(for: URL(fileURLWithPath: path))
    }

    /// Directory name under which the per-project stores persist a project.
    public static func key(for workspaceRootURL: URL) -> String {
        key(forProjectName: projectName(for: workspaceRootURL))
    }

    public static func key(forProjectName name: String) -> String {
        let digest = Data(name.utf8).sha256Hex().prefix(hashLength)
        return "\(stem(for: name))-\(digest)"
    }

    /// Readable part of the key: letters, digits, `-`, `_` and `.` are kept,
    /// any other run of characters becomes `_`.
    static func stem(for name: String) -> String {
        var output = ""
        var lastWasSeparator = false
        for scalar in name.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "-"
                || scalar == "_"
                || scalar == "."
            if isAllowed {
                output.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator {
                output.append("_")
                lastWasSeparator = true
            }
        }
        let trimmed = String(output.unicodeScalars.prefix(maximumStemLength))
            .trimmingCharacters(in: CharacterSet(charactersIn: "._-"))
        return trimmed.isEmpty ? "project" : trimmed
    }
}
