//
//  DS4EngineLibraryLocatorTests.swift
//  ZenCODE
//

import Crypto
import Foundation
import Testing
@testable import ZenCODECore

/// A throwaway DS4 root (with `ds4.h`) and support directory under a UUID-named
/// temporary directory. Never touches the real support directory.
struct DS4EngineBuildFixture {
    let base: URL
    let rootDirectory: String
    let supportDirectory: URL

    init(header: String? = "/* fake ds4.h */\n") throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-engine-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("ds4", isDirectory: true)
        let support = base.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if let header {
            try Data(header.utf8).write(to: root.appendingPathComponent("ds4.h"))
        }
        self.base = base
        self.rootDirectory = try AgentDS4PathGuard.canonicalRootDirectory(root.path)
        self.supportDirectory = support
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func writeHeader(_ header: String) throws {
        try Data(header.utf8).write(to: URL(fileURLWithPath: rootDirectory).appendingPathComponent("ds4.h"))
    }

    /// Creates a library file and (optionally) its `build.json` for `<backend>-<hash>`.
    @discardableResult
    func installLibrary(
        backend: AgentDS4RuntimeBackend,
        hash: String,
        recordedRoot: String? = nil,
        recordedBackend: String? = nil,
        arch: String? = nil,
        writeMetadata: Bool = true,
        modified: Date? = nil
    ) throws -> URL {
        let directory = DS4EngineLibraryLocator.engineDirectory(
            backend: backend,
            hash: hash,
            supportDirectory: supportDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = directory.appendingPathComponent(DS4EngineABI.libraryFileName)
        try Data("library".utf8).write(to: library)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: library.path)
        }
        if writeMetadata {
            let metadata = DS4EngineBuildMetadata(
                root: recordedRoot ?? rootDirectory,
                backend: recordedBackend ?? backend.rawValue,
                arch: arch,
                date: "2026-01-01T00:00:00Z",
                hash: hash,
                abiVersion: DS4EngineABI.expectedVersion
            )
            try JSONEncoder().encode(metadata).write(
                to: directory.appendingPathComponent(DS4EngineLibraryLocator.buildMetadataFileName)
            )
        }
        return library
    }
}

@Suite
struct DS4EngineLibraryLocatorTests {
    // MARK: Hash

    @Test
    func sourceHashIsSHA256PrefixOfHeaderShimAndABI() {
        // SHA-256("abc") = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        #expect(DS4EngineLibraryLocator.sourceHash(ds4Header: Data("abc".utf8), shimSource: "", abiHeader: "")
            == "ba7816bf8f01cfea")
        #expect(DS4EngineLibraryLocator.sourceHash(ds4Header: Data("a".utf8), shimSource: "b", abiHeader: "c")
            == "ba7816bf8f01cfea")
    }

    @Test
    func sourceHashDependsOnTheOrderOfItsInputs() {
        let ordered = DS4EngineLibraryLocator.sourceHash(ds4Header: Data("a".utf8), shimSource: "b", abiHeader: "c")
        let swapped = DS4EngineLibraryLocator.sourceHash(ds4Header: Data("c".utf8), shimSource: "b", abiHeader: "a")
        #expect(ordered != swapped)
    }

    @Test
    func sourceHashOfARootUsesTheEmbeddedSources() throws {
        let fixture = try DS4EngineBuildFixture(header: "int ds4_version(void);\n")
        defer { fixture.remove() }

        let expectedBytes = Data("int ds4_version(void);\n".utf8)
            + Data(DS4EngineShimSources.shimSource.utf8)
            + Data(DS4EngineShimSources.abiHeader.utf8)
        let digest = SHA256.hash(data: expectedBytes).map { String(format: "%02x", $0) }.joined()

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        #expect(hash == String(digest.prefix(16)))
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: Expected URL

    @Test
    func expectedURLIsBackendAndHashUnderTheSupportDirectory() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        for backend in AgentDS4RuntimeBackend.allCases {
            let url = try DS4EngineLibraryLocator.expectedURL(
                rootDirectory: fixture.rootDirectory,
                backend: backend,
                supportDirectory: fixture.supportDirectory
            )
            let expected = fixture.supportDirectory
                .appendingPathComponent("ds4/engines/\(backend.rawValue)-\(hash)/\(DS4EngineABI.libraryFileName)")
            #expect(url.standardizedFileURL == expected.standardizedFileURL)
        }
    }

    @Test
    func expectedURLChangesWhenDS4HeaderChanges() throws {
        let fixture = try DS4EngineBuildFixture(header: "v1\n")
        defer { fixture.remove() }

        let before = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: .cpu,
            supportDirectory: fixture.supportDirectory
        )
        try fixture.writeHeader("v2\n")
        let after = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: .cpu,
            supportDirectory: fixture.supportDirectory
        )
        #expect(before != after)
        #expect(before.deletingLastPathComponent().lastPathComponent.hasPrefix("cpu-"))
    }

    @Test
    func expectedURLFromManifestUsesRootAndBackend() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let manifest = try AgentDS4RuntimeManifest(rootDirectory: fixture.rootDirectory, backend: .cpu)
        let fromManifest = try DS4EngineLibraryLocator.expectedURL(
            manifest: manifest,
            supportDirectory: fixture.supportDirectory
        )
        let explicit = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: .cpu,
            supportDirectory: fixture.supportDirectory
        )
        #expect(fromManifest == explicit)
    }

    @Test
    func expectedURLThrowsWithoutDS4Header() throws {
        let fixture = try DS4EngineBuildFixture(header: nil)
        defer { fixture.remove() }

        #expect(throws: DS4EngineLibraryLocatorError.self) {
            try DS4EngineLibraryLocator.expectedURL(
                rootDirectory: fixture.rootDirectory,
                backend: .metal,
                supportDirectory: fixture.supportDirectory
            )
        }
        #expect(throws: AgentDS4PathValidationError.self) {
            try DS4EngineLibraryLocator.expectedURL(
                rootDirectory: "relative/ds4",
                backend: .metal,
                supportDirectory: fixture.supportDirectory
            )
        }
    }

    @Test
    func effectiveArchDefaultsForCUDAAndROCmOnly() {
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .cuda, arch: nil) == "native")
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .cuda, arch: "  ") == "native")
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .cuda, arch: " sm_120 ") == "sm_120")
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .rocm, arch: nil) == "gfx1151")
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .rocm, arch: "gfx1100") == "gfx1100")
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .metal, arch: "sm_120") == nil)
        #expect(DS4EngineLibraryLocator.effectiveArch(backend: .cpu, arch: "sm_120") == nil)
    }

    // MARK: Status

    private func status(
        _ fixture: DS4EngineBuildFixture,
        backend: AgentDS4RuntimeBackend,
        arch: String? = nil
    ) -> DS4EngineLibraryStatus {
        DS4EngineLibraryLocator.status(
            rootDirectory: fixture.rootDirectory,
            backend: backend,
            arch: arch,
            supportDirectory: fixture.supportDirectory
        )
    }

    private func expected(_ fixture: DS4EngineBuildFixture, backend: AgentDS4RuntimeBackend) throws -> URL {
        try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: backend,
            supportDirectory: fixture.supportDirectory
        )
    }

    @Test
    func statusIsMissingWhenNothingWasBuilt() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        #expect(status(fixture, backend: .metal) == .missing(expected: try expected(fixture, backend: .metal)))
    }

    @Test
    func statusIsBuiltWhenTheExpectedLibraryAndMetadataMatch() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(backend: .metal, hash: hash)
        #expect(status(fixture, backend: .metal) == .built(library))
    }

    @Test
    func statusIgnoresTheSpellingOfTheRecordedRoot() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(
            backend: .cpu,
            hash: hash,
            recordedRoot: fixture.rootDirectory + "/../ds4/"
        )
        #expect(status(fixture, backend: .cpu) == .built(library))
    }

    @Test
    func statusIsStaleWhenAnotherHashExistsForTheSameBackend() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let old = try fixture.installLibrary(backend: .metal, hash: "0123456789abcdef")
        #expect(status(fixture, backend: .metal) == .stale(
            found: old,
            expected: try expected(fixture, backend: .metal)
        ))
    }

    @Test
    func statusReportsTheNewestOfSeveralStaleLibraries() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        try fixture.installLibrary(
            backend: .metal,
            hash: "aaaaaaaaaaaaaaaa",
            modified: Date(timeIntervalSince1970: 1_000)
        )
        let newest = try fixture.installLibrary(
            backend: .metal,
            hash: "bbbbbbbbbbbbbbbb",
            modified: Date(timeIntervalSince1970: 2_000)
        )
        #expect(status(fixture, backend: .metal) == .stale(
            found: newest,
            expected: try expected(fixture, backend: .metal)
        ))
    }

    @Test
    func statusIgnoresLibrariesOfOtherBackendsAndForeignDirectories() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        try fixture.installLibrary(backend: .cpu, hash: "0123456789abcdef")
        let enginesDirectory = DS4EngineLibraryLocator.enginesDirectory(supportDirectory: fixture.supportDirectory)
        for name in ["metal-notahash", "metal-0123456789ABCDEF", "metal-0123456789abcdef0"] {
            let directory = enginesDirectory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("library".utf8).write(to: directory.appendingPathComponent(DS4EngineABI.libraryFileName))
        }
        // A directory of the right shape without a library inside is not a library either.
        try FileManager.default.createDirectory(
            at: DS4EngineLibraryLocator.engineDirectory(
                backend: .metal,
                hash: "fedcba9876543210",
                supportDirectory: fixture.supportDirectory
            ),
            withIntermediateDirectories: true
        )
        #expect(status(fixture, backend: .metal) == .missing(expected: try expected(fixture, backend: .metal)))
    }

    @Test
    func statusIsStaleWhenTheRecordedRootDiffers() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(backend: .metal, hash: hash, recordedRoot: "/somewhere/else/ds4")
        #expect(status(fixture, backend: .metal) == .stale(found: library, expected: library))
    }

    @Test
    func statusIsStaleWhenTheRecordedBackendDiffers() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(backend: .metal, hash: hash, recordedBackend: "cpu")
        #expect(status(fixture, backend: .metal) == .stale(found: library, expected: library))
    }

    @Test
    func statusIsStaleWithoutOrWithUnreadableBuildMetadata() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(backend: .metal, hash: hash, writeMetadata: false)
        #expect(status(fixture, backend: .metal) == .stale(found: library, expected: library))

        try Data("not json".utf8).write(
            to: library.deletingLastPathComponent()
                .appendingPathComponent(DS4EngineLibraryLocator.buildMetadataFileName)
        )
        #expect(status(fixture, backend: .metal) == .stale(found: library, expected: library))
    }

    @Test
    func statusComparesTheArchitectureOfCUDAAndROCmBuilds() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let cuda = try fixture.installLibrary(backend: .cuda, hash: hash, arch: "sm_120")
        #expect(status(fixture, backend: .cuda, arch: "sm_120") == .built(cuda))
        #expect(status(fixture, backend: .cuda, arch: "sm_90") == .stale(found: cuda, expected: cuda))
        #expect(status(fixture, backend: .cuda, arch: nil) == .stale(found: cuda, expected: cuda))

        let rocm = try fixture.installLibrary(backend: .rocm, hash: hash, arch: "gfx1151")
        #expect(status(fixture, backend: .rocm, arch: nil) == .built(rocm))
        #expect(status(fixture, backend: .rocm, arch: "gfx1151") == .built(rocm))
        #expect(status(fixture, backend: .rocm, arch: "gfx1100") == .stale(found: rocm, expected: rocm))
    }

    @Test
    func statusTreatsDefaultCUDAArchitectureAsNative() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let cuda = try fixture.installLibrary(backend: .cuda, hash: hash, arch: "native")
        #expect(status(fixture, backend: .cuda, arch: nil) == .built(cuda))
        #expect(status(fixture, backend: .cuda, arch: "native") == .built(cuda))
    }

    @Test
    func statusIgnoresTheArchitectureOfMetalAndCPUBuilds() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let cpu = try fixture.installLibrary(backend: .cpu, hash: hash)
        #expect(status(fixture, backend: .cpu, arch: "sm_120") == .built(cpu))
    }

    @Test
    func statusBecomesStaleWhenDS4HeaderChanges() throws {
        let fixture = try DS4EngineBuildFixture(header: "v1\n")
        defer { fixture.remove() }

        let oldHash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let old = try fixture.installLibrary(backend: .metal, hash: oldHash)
        #expect(status(fixture, backend: .metal) == .built(old))

        try fixture.writeHeader("v2\n")
        #expect(status(fixture, backend: .metal) == .stale(
            found: old,
            expected: try expected(fixture, backend: .metal)
        ))
    }

    @Test
    func statusIsMissingWithAPlaceholderWhenDS4HeaderIsAbsent() throws {
        let fixture = try DS4EngineBuildFixture(header: nil)
        defer { fixture.remove() }

        guard case let .missing(placeholder) = status(fixture, backend: .metal) else {
            Issue.record("expected .missing")
            return
        }
        #expect(placeholder.deletingLastPathComponent().lastPathComponent == "metal-unavailable")
        #expect(placeholder.lastPathComponent == DS4EngineABI.libraryFileName)
    }

    @Test
    func buildMetadataDecodesTheScriptOutput() throws {
        let json = """
        {
          "root": "/Users/me/ds4",
          "backend": "cuda",
          "arch": "sm_120",
          "date": "2026-10-25T22:46:57Z",
          "hash": "dfaf2cc34e66aa67",
          "abiVersion": 1
        }
        """
        let metadata = try JSONDecoder().decode(DS4EngineBuildMetadata.self, from: Data(json.utf8))
        #expect(metadata.root == "/Users/me/ds4")
        #expect(metadata.backend == "cuda")
        #expect(metadata.arch == "sm_120")
        #expect(metadata.hash == "dfaf2cc34e66aa67")
        #expect(metadata.abiVersion == 1)

        let nullArch = #"{"root":"/r","backend":"metal","arch":null,"date":"d","hash":"h","abiVersion":1}"#
        #expect(try JSONDecoder().decode(DS4EngineBuildMetadata.self, from: Data(nullArch.utf8)).arch == nil)
    }
}
