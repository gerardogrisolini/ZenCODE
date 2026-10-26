//
//  DS4EngineLibraryLocator.swift
//  ZenCODE
//
//  Where the in-process DS4 engine library lives and whether it is current.
//
//  The library is built on the user's machine by `DS4EngineBuilder` into
//  `<support>/ds4/engines/<backend>-<hash16>/libzencode-ds4.{dylib,so}`, where
//  `hash16` is the first 16 hex characters of
//  SHA-256(`ds4.h` of the DS4 root ∥ embedded `zencode_ds4_shim.c` ∥ embedded
//  `zencode_ds4_abi.h`). A new DS4 header or a new ZenCODE shim therefore maps
//  to a different directory, and the old one is reported as stale. Next to the
//  library `Scripts/build-ds4-engine.sh` writes `build.json` (root, backend,
//  arch, date, hash, abiVersion): a different root or architecture is stale too.
//

import Crypto
import Foundation

/// State of the engine library for one DS4 root and backend.
enum DS4EngineLibraryStatus: Equatable, Sendable {
    /// The library for the current sources, root and architecture exists.
    case built(URL)
    /// Nothing has been built for this backend yet.
    case missing(expected: URL)
    /// A library exists but was built from other sources, another root or another
    /// architecture: it must be rebuilt at `expected`.
    case stale(found: URL, expected: URL)
}

enum DS4EngineLibraryLocatorError: LocalizedError, Equatable, Sendable {
    case ds4HeaderMissing(String)

    var errorDescription: String? {
        switch self {
        case let .ds4HeaderMissing(path):
            return "ds4.h not found at \(path). Point ZenCODE at a DS4 checkout that contains ds4.h."
        }
    }
}

/// Content of `build.json`, written by `Scripts/build-ds4-engine.sh` next to the
/// library. Only `root`, `backend` and `arch` take part in the status check; the
/// other fields are informational and decoded leniently.
struct DS4EngineBuildMetadata: Codable, Equatable, Sendable {
    let root: String
    let backend: String
    let arch: String?
    let date: String?
    let hash: String?
    let abiVersion: Int32?
}

enum DS4EngineLibraryLocator {
    /// File name of the build record next to the library.
    static let buildMetadataFileName = "build.json"

    /// Architecture used when the caller does not choose one: the CUDA backend
    /// builds for the installed GPU, the ROCm backend targets Strix Halo.
    static let defaultCUDAArch = "native"
    static let defaultROCmArch = "gfx1151"

    // MARK: Layout

    /// `<support>/ds4`
    static func ds4Directory(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("ds4", isDirectory: true)
    }

    /// `<support>/ds4/shim`: where the embedded shim sources and build script are extracted.
    static func shimDirectory(supportDirectory: URL) -> URL {
        ds4Directory(supportDirectory: supportDirectory).appendingPathComponent("shim", isDirectory: true)
    }

    /// `<support>/ds4/engines`
    static func enginesDirectory(supportDirectory: URL) -> URL {
        ds4Directory(supportDirectory: supportDirectory).appendingPathComponent("engines", isDirectory: true)
    }

    /// `<support>/ds4/engines/<backend>-<hash16>`
    static func engineDirectory(
        backend: AgentDS4RuntimeBackend,
        hash: String,
        supportDirectory: URL
    ) -> URL {
        enginesDirectory(supportDirectory: supportDirectory)
            .appendingPathComponent("\(backend.rawValue)-\(hash)", isDirectory: true)
    }

    // MARK: Expected location

    /// Where the library for `rootDirectory` and `backend` is expected, whether or
    /// not it exists. Throws when the root is not an absolute path or has no `ds4.h`.
    static func expectedURL(
        rootDirectory: String,
        backend: AgentDS4RuntimeBackend,
        supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()
    ) throws -> URL {
        let hash = try sourceHash(rootDirectory: rootDirectory)
        return engineDirectory(backend: backend, hash: hash, supportDirectory: supportDirectory)
            .appendingPathComponent(DS4EngineABI.libraryFileName, isDirectory: false)
    }

    /// Same as `expectedURL(rootDirectory:backend:supportDirectory:)` for the root and backend of a manifest.
    static func expectedURL(
        manifest: AgentDS4RuntimeManifest,
        supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()
    ) throws -> URL {
        try expectedURL(
            rootDirectory: manifest.rootDirectory,
            backend: manifest.backend,
            supportDirectory: supportDirectory
        )
    }

    // MARK: Hash

    /// First 16 hex characters of SHA-256(`ds4.h` ∥ embedded shim source ∥ embedded ABI header).
    static func sourceHash(rootDirectory: String) throws -> String {
        let root = try AgentDS4PathGuard.canonicalRootDirectory(rootDirectory)
        let headerPath = URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent("ds4.h", isDirectory: false).path
        guard let header = FileManager.default.contents(atPath: headerPath) else {
            throw DS4EngineLibraryLocatorError.ds4HeaderMissing(headerPath)
        }
        return sourceHash(
            ds4Header: header,
            shimSource: DS4EngineShimSources.shimSource,
            abiHeader: DS4EngineShimSources.abiHeader
        )
    }

    /// Pure form of the hash, in the order used by `Scripts/build-ds4-engine.sh`.
    static func sourceHash(ds4Header: Data, shimSource: String, abiHeader: String) -> String {
        var hasher = SHA256()
        hasher.update(data: ds4Header)
        hasher.update(data: Data(shimSource.utf8))
        hasher.update(data: Data(abiHeader.utf8))
        let hex = hasher.finalize().map { byte -> String in
            let digits = String(byte, radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
        return String(hex.prefix(16))
    }

    // MARK: Architecture

    /// The architecture a build for `backend` records in `build.json`: the
    /// requested one (or the default) for CUDA and ROCm, `nil` for the others.
    static func effectiveArch(backend: AgentDS4RuntimeBackend, arch: String?) -> String? {
        let requested = arch?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = (requested?.isEmpty ?? true) ? nil : requested
        switch backend {
        case .cuda:
            return explicit ?? defaultCUDAArch
        case .rocm:
            return explicit ?? defaultROCmArch
        case .metal, .cpu:
            return nil
        }
    }

    // MARK: Status

    /// Whether the library for `rootDirectory`, `backend` and `arch` is built,
    /// missing or stale. `arch` only matters for CUDA and ROCm (`nil` means the default).
    ///
    /// Without a readable `ds4.h` the expected location cannot be derived: the
    /// result is `.missing` with a placeholder `<backend>-unavailable` path, and
    /// `expectedURL` reports the actual error.
    static func status(
        rootDirectory: String,
        backend: AgentDS4RuntimeBackend,
        arch: String?,
        supportDirectory: URL = AppStorageDirectory.appSupportDirectoryURL()
    ) -> DS4EngineLibraryStatus {
        guard let root = try? AgentDS4PathGuard.canonicalRootDirectory(rootDirectory),
              let expected = try? expectedURL(
                  rootDirectory: root,
                  backend: backend,
                  supportDirectory: supportDirectory
              )
        else {
            return .missing(expected: engineDirectory(
                backend: backend,
                hash: "unavailable",
                supportDirectory: supportDirectory
            ).appendingPathComponent(DS4EngineABI.libraryFileName, isDirectory: false))
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: expected.path) {
            let recorded = buildMetadata(inDirectory: expected.deletingLastPathComponent())
            if let recorded,
               normalizedPath(recorded.root) == normalizedPath(root),
               recorded.backend == backend.rawValue,
               recorded.arch == effectiveArch(backend: backend, arch: arch)
            {
                return .built(expected)
            }
            return .stale(found: expected, expected: expected)
        }

        if let other = newestLibrary(
            backend: backend,
            excluding: expected.deletingLastPathComponent(),
            supportDirectory: supportDirectory
        ) {
            return .stale(found: other, expected: expected)
        }
        return .missing(expected: expected)
    }

    /// Decoded `build.json` in an engine directory, or `nil` when absent or unreadable.
    static func buildMetadata(inDirectory directory: URL) -> DS4EngineBuildMetadata? {
        let url = directory.appendingPathComponent(buildMetadataFileName, isDirectory: false)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            return nil
        }
        return try? JSONDecoder().decode(DS4EngineBuildMetadata.self, from: data)
    }

    // MARK: Private

    /// The most recently modified library of `backend` in a directory other than `excluded`.
    private static func newestLibrary(
        backend: AgentDS4RuntimeBackend,
        excluding excluded: URL,
        supportDirectory: URL
    ) -> URL? {
        let fileManager = FileManager.default
        let enginesDirectory = enginesDirectory(supportDirectory: supportDirectory)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: enginesDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let prefix = "\(backend.rawValue)-"
        let excludedName = excluded.lastPathComponent
        let candidates: [(url: URL, modified: Date)] = entries.compactMap { entry in
            // URLs are rebuilt from the support directory (not taken from the
            // listing, which may spell it differently, e.g. /private/var).
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix),
                  name != excludedName,
                  isHashSuffix(String(name.dropFirst(prefix.count)))
            else {
                return nil
            }
            let library = enginesDirectory
                .appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(DS4EngineABI.libraryFileName, isDirectory: false)
            guard let attributes = try? fileManager.attributesOfItem(atPath: library.path) else {
                return nil
            }
            return (library, (attributes[.modificationDate] as? Date) ?? .distantPast)
        }
        return candidates
            .sorted { lhs, rhs in
                lhs.modified != rhs.modified
                    ? lhs.modified > rhs.modified
                    : lhs.url.path < rhs.url.path
            }
            .first?.url
    }

    private static func isHashSuffix(_ value: String) -> Bool {
        value.count == 16 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// Absolute, symlink-free spelling used to compare the root of `build.json`
    /// with the requested one.
    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
