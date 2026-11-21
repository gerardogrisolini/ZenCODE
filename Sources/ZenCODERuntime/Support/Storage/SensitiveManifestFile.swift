//
//  SensitiveManifestFile.swift
//  ZenCODE
//
//  The reading and the encoding the versioned manifests of the support
//  directory share (`settings.json`, `permissions.json`): permissions
//  hardened before every read, one error for each way a read fails, and the
//  pretty-printed JSON they are written as.
//

import Foundation

/// A versioned JSON manifest kept in the support directory with sensitive
/// file permissions.
protocol SensitiveVersionedManifest: Decodable {
    static var minimumSupportedVersion: Int { get }
    static var currentVersion: Int { get }
    var version: Int { get }
}

/// The errors a manifest store reports for each way a read fails; the cases
/// of each store's public error satisfy it.
protocol SensitiveManifestStoreError: Error {
    static func missingFile(_ url: URL) -> Self
    static func unreadableFile(_ url: URL, _ error: Error) -> Self
    static func invalidFile(_ url: URL, _ error: Error) -> Self
    static func unsupportedVersion(_ url: URL, _ found: Int, _ expected: Int) -> Self
}

enum SensitiveManifestFile {
    /// Reads the manifest at `url` without taking the manifest lock: the file
    /// must exist, its permissions are hardened before it is read, and its
    /// version must be within the supported range. Each failure throws the
    /// matching case of `Failure`.
    static func loadUnlocked<Manifest: SensitiveVersionedManifest, Failure: SensitiveManifestStoreError>(
        _: Manifest.Type,
        from url: URL,
        failure _: Failure.Type
    ) throws -> Manifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.missingFile(url)
        }

        let data: Data
        do {
            try SensitiveFilePermissions.hardenExistingFile(at: url)
            data = try Data(contentsOf: url)
        } catch {
            throw Failure.unreadableFile(url, error)
        }

        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw Failure.invalidFile(url, error)
        }

        guard manifest.version >= Manifest.minimumSupportedVersion,
              manifest.version <= Manifest.currentVersion else {
            throw Failure.unsupportedVersion(url, manifest.version, Manifest.currentVersion)
        }
        return manifest
    }

    /// The pretty-printed JSON a manifest is written as.
    static func encodedData(_ manifest: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        return try encoder.encode(manifest)
    }
}
