//
//  BrowserArtifacts.swift
//  BrowserToolsFeature
//
//  Durable, bounded Browser artefacts such as screenshots.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum BrowserArtifactError: LocalizedError {
    case emptyArtifact(String)

    var errorDescription: String? {
        switch self {
        case let .emptyArtifact(kind):
            "Chrome returned an empty \(kind) artifact."
        }
    }
}

struct BrowserArtifact: Codable, Hashable, Sendable {
    let path: String
    let mimeType: String
    let sizeBytes: Int
}

struct BrowserScreenshotOutput: Codable, Sendable {
    let page: BrowserPage
    let artifact: BrowserArtifact
    let fullPage: Bool
    let note: String

    init(page: BrowserPage, artifact: BrowserArtifact, fullPage: Bool) {
        self.page = page
        self.artifact = artifact
        self.fullPage = fullPage
        self.note = "The PNG is stored as a Browser artifact and is not embedded in the model transcript."
    }
}

/// Owns Browser-produced files only. Tool callers cannot choose a destination,
/// so a page cannot turn screenshots into arbitrary filesystem writes.
struct BrowserArtifactStore: Sendable {
    static let defaultMaximumArtifactCount = 50
    static let defaultRetentionAge: TimeInterval = 7 * 24 * 60 * 60

    let rootDirectory: URL
    let maximumArtifactCount: Int
    let retentionAge: TimeInterval

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumArtifactCount: Int = BrowserArtifactStore.defaultMaximumArtifactCount,
        retentionAge: TimeInterval = BrowserArtifactStore.defaultRetentionAge
    ) {
        self.init(
            rootDirectory: ChromeBrowserConfiguration(environment: environment)
                .profileDirectory
                .appendingPathComponent("artifacts", isDirectory: true),
            maximumArtifactCount: maximumArtifactCount,
            retentionAge: retentionAge
        )
    }

    init(
        rootDirectory: URL,
        maximumArtifactCount: Int = BrowserArtifactStore.defaultMaximumArtifactCount,
        retentionAge: TimeInterval = BrowserArtifactStore.defaultRetentionAge
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.maximumArtifactCount = max(maximumArtifactCount, 1)
        self.retentionAge = max(retentionAge, 0)
    }

    func storeScreenshotPNG(_ data: Data, pageID: String) throws -> BrowserArtifact {
        try store(
            data,
            pageID: pageID,
            prefix: "screenshot",
            fileExtension: "png",
            mimeType: "image/png"
        )
    }

    func storePDF(_ data: Data, pageID: String) throws -> BrowserArtifact {
        try store(
            data,
            pageID: pageID,
            prefix: "page",
            fileExtension: "pdf",
            mimeType: "application/pdf"
        )
    }

    private func store(
        _ data: Data,
        pageID: String,
        prefix: String,
        fileExtension: String,
        mimeType: String
    ) throws -> BrowserArtifact {
        guard !data.isEmpty else { throw BrowserArtifactError.emptyArtifact(prefix) }
        try prepareDirectory()

        let filename = "\(prefix)-\(safePagePrefix(pageID))-\(UUID().uuidString.lowercased()).\(fileExtension)"
        let destination = rootDirectory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: destination, options: .atomic)
        try setPermissions(0o600, at: destination)
        try pruneRetainedArtifacts(preserving: destination)

        return BrowserArtifact(
            path: destination.path,
            mimeType: mimeType,
            sizeBytes: data.count
        )
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: rootDirectory)
    }

    private func pruneRetainedArtifacts(
        now: Date = Date(),
        preserving preservedURL: URL? = nil
    ) throws {
        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .creationDateKey,
            .isRegularFileKey,
        ]
        let contents = try fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        var retained: [(url: URL, date: Date)] = []

        for url in contents where ["pdf", "png"].contains(url.pathExtension.lowercased()) {
            let values = try? url.resourceValues(forKeys: resourceKeys)
            guard values?.isRegularFile != false else { continue }
            let date = values?.contentModificationDate ?? values?.creationDate ?? .distantPast
            if url == preservedURL {
                retained.append((url, date))
            } else if now.timeIntervalSince(date) > retentionAge {
                try? fileManager.removeItem(at: url)
            } else {
                retained.append((url, date))
            }
        }

        retained.sort { lhs, rhs in
            if lhs.url == preservedURL { return true }
            if rhs.url == preservedURL { return false }
            return lhs.date > rhs.date
        }
        guard retained.count > maximumArtifactCount else { return }
        for artifact in retained.dropFirst(maximumArtifactCount) {
            try? fileManager.removeItem(at: artifact.url)
        }
    }

    private func safePagePrefix(_ pageID: String) -> String {
        let safeScalars = pageID.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
        }
        let prefix = String(String.UnicodeScalarView(safeScalars)).prefix(12)
        return prefix.isEmpty ? "page" : String(prefix)
    }

    private func setPermissions(_ permissions: Int, at url: URL) throws {
        #if canImport(Darwin) || canImport(Glibc)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
        #endif
    }
}
