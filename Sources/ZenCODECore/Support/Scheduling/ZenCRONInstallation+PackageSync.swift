//
//  ZenCRONInstallation+PackageSync.swift
//  ZenCODE
//

import Foundation

extension ZenCRONInstallation {
    /// Entries that are never copied into the working copy nor removed from it:
    /// SwiftPM and editor state. The `.build` directory of the working copy is
    /// what makes the next build incremental.
    static let packageSyncExcludedNames: Set<String> = [".build", ".swiftpm", ".git", ".DS_Store"]

    /// Makes `destination` a copy of the package at `source`.
    ///
    /// - `.build` (and the other `packageSyncExcludedNames`) is not copied, and
    ///   the one already in `destination` is kept, so builds stay incremental.
    /// - Files whose content did not change are left alone, so their
    ///   modification dates do not trigger a rebuild.
    /// - Entries of `destination` that no longer exist in `source` are removed.
    static func syncPackage(
        from source: URL,
        to destination: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try mirrorDirectory(from: source, to: destination, fileManager: fileManager)
    }

    private enum EntryKind {
        case directory
        case symbolicLink
        case file
    }

    private static func kind(of url: URL, fileManager: FileManager) -> EntryKind? {
        guard let type = (try? fileManager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else {
            return nil
        }
        switch type {
        case .typeDirectory:
            return .directory
        case .typeSymbolicLink:
            return .symbolicLink
        default:
            return .file
        }
    }

    private static func mirrorDirectory(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws {
        let sourceNames = try fileManager.contentsOfDirectory(atPath: source.path)
            .filter { !packageSyncExcludedNames.contains($0) }
        let destinationNames = try fileManager.contentsOfDirectory(atPath: destination.path)
            .filter { !packageSyncExcludedNames.contains($0) }

        for name in Set(destinationNames).subtracting(sourceNames) {
            try fileManager.removeItem(at: destination.appendingPathComponent(name))
        }

        for name in sourceNames.sorted() {
            let sourceEntry = source.appendingPathComponent(name)
            let destinationEntry = destination.appendingPathComponent(name)
            let sourceKind = kind(of: sourceEntry, fileManager: fileManager)
            let destinationKind = kind(of: destinationEntry, fileManager: fileManager)

            switch sourceKind {
            case .directory:
                if destinationKind != .directory {
                    if destinationKind != nil {
                        try fileManager.removeItem(at: destinationEntry)
                    }
                    try fileManager.createDirectory(
                        at: destinationEntry,
                        withIntermediateDirectories: false
                    )
                }
                try mirrorDirectory(from: sourceEntry, to: destinationEntry, fileManager: fileManager)
            case .symbolicLink:
                let linkTarget = try fileManager.destinationOfSymbolicLink(atPath: sourceEntry.path)
                if destinationKind == .symbolicLink,
                   (try? fileManager.destinationOfSymbolicLink(atPath: destinationEntry.path)) == linkTarget {
                    continue
                }
                if destinationKind != nil {
                    try fileManager.removeItem(at: destinationEntry)
                }
                try fileManager.createSymbolicLink(
                    atPath: destinationEntry.path,
                    withDestinationPath: linkTarget
                )
            case .file:
                if destinationKind == .file,
                   fileManager.contentsEqual(atPath: sourceEntry.path, andPath: destinationEntry.path) {
                    continue
                }
                if destinationKind != nil {
                    try fileManager.removeItem(at: destinationEntry)
                }
                try fileManager.copyItem(at: sourceEntry, to: destinationEntry)
            case nil:
                continue
            }
        }
    }
}
