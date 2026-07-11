//
//  PackageRootResolver.swift
//  ZenCODE
//

import Foundation

/// Locates a Swift package manifest from a source file without relying on a
/// fixed number of parent-directory traversals.
enum PackageRootResolver {
    static func packageRoot(
        forSourceFilePath sourceFilePath: String,
        fileManager: FileManager = .default
    ) -> URL? {
        var directoryURL = sourceDirectory(forSourceFilePath: sourceFilePath)

        while true {
            if fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent("Package.swift").path
            ) {
                return directoryURL
            }

            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                return nil
            }
            directoryURL = parentURL
        }
    }

    /// Returns the source file's ancestor, stopping at the filesystem root.
    /// Used only to retain a legacy fallback when no source package is present.
    static func sourceDirectory(
        forSourceFilePath sourceFilePath: String,
        ancestorCount: Int = 0
    ) -> URL {
        var directoryURL = URL(fileURLWithPath: sourceFilePath)
            .deletingLastPathComponent()
            .standardizedFileURL

        for _ in 0..<max(ancestorCount, 0) {
            let parentURL = directoryURL.deletingLastPathComponent()
            guard parentURL.path != directoryURL.path else {
                return directoryURL
            }
            directoryURL = parentURL
        }

        return directoryURL
    }
}
