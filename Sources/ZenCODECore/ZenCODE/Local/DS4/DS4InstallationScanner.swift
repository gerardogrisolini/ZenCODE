//
//  DS4InstallationScanner.swift
//  ZenCODE
//
//  Read-only discovery of GGUF artifacts in a DS4 checkout.
//

import Foundation

public struct DS4InstalledArtifact: Codable, Equatable, Hashable, Sendable {
    public let relativePath: String
    public let url: URL
    /// File size on disk. This is not a RAM/residency estimate.
    public let diskBytes: UInt64

    public init(relativePath: String, url: URL, diskBytes: UInt64) {
        self.relativePath = relativePath
        self.url = url
        self.diskBytes = diskBytes
    }
}

/// Compatibility spelling for callers that call discovered GGUFs models.
public typealias DS4InstalledModel = DS4InstalledArtifact

public struct DS4InstallationSnapshot: Codable, Equatable, Hashable, Sendable {
    public let rootDirectory: String
    public let artifacts: [DS4InstalledArtifact]
    public let scannedDirectories: [String]
    public let diagnostics: [String]

    public init(
        rootDirectory: String,
        artifacts: [DS4InstalledArtifact] = [],
        scannedDirectories: [String] = [],
        diagnostics: [String] = []
    ) {
        self.rootDirectory = rootDirectory
        self.artifacts = artifacts
        self.scannedDirectories = scannedDirectories
        self.diagnostics = diagnostics
    }

    public var totalDiskBytes: UInt64 {
        artifacts.reduce(0) { partial, artifact in
            let (sum, overflow) = partial.addingReportingOverflow(artifact.diskBytes)
            return overflow ? UInt64.max : sum
        }
    }

    public func contains(relativePath: String) -> Bool {
        let normalized = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        return artifacts.contains { $0.relativePath == normalized }
    }

    public func artifact(relativePath: String) -> DS4InstalledArtifact? {
        let normalized = relativePath
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        return artifacts.first { $0.relativePath == normalized }
    }
}

public enum DS4InstallationScannerError: LocalizedError, Equatable, Sendable {
    case rootDirectoryMissing(String)
    case rootDirectoryUnreadable(String)

    public var errorDescription: String? {
        switch self {
        case let .rootDirectoryMissing(path):
            return "The DS4 installation root does not exist or is not a directory: \(path)"
        case let .rootDirectoryUnreadable(path):
            return "The DS4 installation root could not be enumerated: \(path)"
        }
    }
}

/// Scans only `root/*.gguf` and `root/gguf/*.gguf`. It deliberately does not
/// recurse through arbitrary project paths, caches, or user-selected folders.
public struct DS4InstallationScanner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func scan(rootDirectory: String) throws -> DS4InstallationSnapshot {
        let rootPath = try AgentDS4PathGuard.canonicalRootDirectory(
            rootDirectory,
            fileManager: fileManager
        )
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw DS4InstallationScannerError.rootDirectoryMissing(rootPath)
        }

        var diagnostics: [String] = []
        var scannedDirectories: [String] = []
        var artifacts: [DS4InstalledArtifact] = []
        let directories = [
            rootURL,
            rootURL.appendingPathComponent("gguf", isDirectory: true)
        ]

        for directoryURL in directories {
            if directoryURL.path != rootURL.path,
               isSymbolicLink(directoryURL) {
                diagnostics.append("Ignored symbolic-link GGUF directory: \(relativePath(of: directoryURL, root: rootURL)).")
                continue
            }
            var directoryFlag: ObjCBool = false
            guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &directoryFlag) else {
                if directoryURL.lastPathComponent == "gguf" {
                    diagnostics.append("GGUF directory is not installed: gguf.")
                }
                continue
            }
            guard directoryFlag.boolValue else {
                if directoryURL.lastPathComponent == "gguf" {
                    diagnostics.append("GGUF path is not a directory: gguf.")
                }
                continue
            }
            scannedDirectories.append(relativePath(of: directoryURL, root: rootURL))

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                if directoryURL == rootURL {
                    throw DS4InstallationScannerError.rootDirectoryUnreadable(rootPath)
                }
                diagnostics.append("Unable to enumerate gguf directory: \(error.localizedDescription)")
                continue
            }

            for entryURL in entries {
                guard entryURL.pathExtension.lowercased() == "gguf" else { continue }
                if isSymbolicLink(entryURL) {
                    diagnostics.append("Ignored symbolic-link GGUF artifact: \(relativePath(of: entryURL, root: rootURL)).")
                    continue
                }
                let values = try? entryURL.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
                )
                guard values?.isDirectory != true, values?.isRegularFile == true else {
                    diagnostics.append("Ignored non-regular GGUF artifact: \(relativePath(of: entryURL, root: rootURL)).")
                    continue
                }
                guard let fileSize = values?.fileSize, fileSize >= 0 else {
                    diagnostics.append("GGUF artifact size is unavailable: \(relativePath(of: entryURL, root: rootURL)).")
                    continue
                }
                artifacts.append(
                    DS4InstalledArtifact(
                        relativePath: relativePath(of: entryURL, root: rootURL),
                        url: entryURL.standardizedFileURL,
                        diskBytes: UInt64(fileSize)
                    )
                )
            }
        }

        var seen = Set<String>()
        artifacts = artifacts
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            .filter { seen.insert($0.relativePath).inserted }

        return DS4InstallationSnapshot(
            rootDirectory: rootPath,
            artifacts: artifacts,
            scannedDirectories: scannedDirectories,
            diagnostics: diagnostics
        )
    }

    public func scan(rootDirectory: URL) throws -> DS4InstallationSnapshot {
        try scan(rootDirectory: rootDirectory.path)
    }

    /// Compatibility spelling for callers that pass a manifest root.
    public func scan(_ manifest: AgentDS4RuntimeManifest) throws -> DS4InstallationSnapshot {
        try scan(rootDirectory: manifest.rootDirectory)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeSymbolicLink
    }

    private func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == rootPath { return "." }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        return String(path.dropFirst(prefix.count)).replacingOccurrences(of: "\\", with: "/")
    }
}

/// Compatibility spelling for a scanner result.
public typealias DS4InstallationReport = DS4InstallationSnapshot
