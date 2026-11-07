//
//  DS4EngineLibraryTests.swift
//  ZenCODE
//
//  Library loading and ABI contract. Drift guards parse
//  `zencode_ds4_abi.h` and compare it with the Swift mirror; loader errors
//  are exercised with missing files, non-library files and tiny fake
//  libraries compiled with the system C compiler (skipped without one).
//
//  Real-library checks run only when ZENCODE_DS4_ENGINE_LIBRARY points to a
//  built libzencode-ds4: they never load a model (the shim rejects the open
//  before ds4_engine_open).
//

import Foundation
import Testing
@testable import ZenCODECore
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

private enum DS4LibraryFixtures {
    static let hint = "Scripts/build-ds4-engine.sh --ds4-root /tmp/ds4"

    static var headerURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DS4
            .deletingLastPathComponent() // Local
            .deletingLastPathComponent() // ZenCODECoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Sources/ZenCODECore/Resources/DS4Engine/zencode_ds4_abi.h")
    }

    static func header() throws -> String {
        try String(contentsOf: headerURL, encoding: .utf8)
    }

    static func matches(_ pattern: String, in text: String) throws -> [[String]] {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ds4-engine-library-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let compilerPath: String? = ["/usr/bin/cc", "/usr/bin/clang", "/usr/bin/gcc"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Compiles `source` into a shared library in `directory`.
    static func buildLibrary(source: String, in directory: URL) throws -> URL {
        let compiler = try #require(compilerPath)
        let sourceURL = directory.appendingPathComponent("fake.c")
        let libraryURL = directory.appendingPathComponent(DS4EngineABI.libraryFileName)
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["-shared", "-fPIC", "-o", libraryURL.path, sourceURL.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return libraryURL
    }
}

@Suite
struct DS4EngineLibraryTests {
    // MARK: Header drift guards

    @Test
    func symbolNamesMatchTheHeaderExports() throws {
        let header = try DS4LibraryFixtures.header()
        let exported = try DS4LibraryFixtures.matches(
            #"ZENCODE_DS4_EXPORT\s+[^;(]*?\b(zencode_ds4_\w+)\s*\("#,
            in: header
        ).compactMap(\.first)

        #expect(exported == DS4EngineABI.symbolNames)
        #expect(DS4EngineABI.symbolNames.count == 46)
    }

    @Test
    func constantsMatchTheHeader() throws {
        let header = try DS4LibraryFixtures.header()
        var defined: [String: Int32] = [:]
        for match in try DS4LibraryFixtures.matches(#"#define\s+(ZENCODE_DS4_\w+)\s+(-?\d+)"#, in: header) {
            defined[match[0]] = Int32(match[1])
        }
        let mirrored: [String: Int32] = [
            "ZENCODE_DS4_ABI_VERSION": DS4EngineABI.expectedVersion,
            "ZENCODE_DS4_OK": DS4EngineABI.ok,
            "ZENCODE_DS4_SYNC_INTERRUPTED": DS4EngineABI.syncInterrupted,
            "ZENCODE_DS4_GENERATE_STOP": DS4EngineABI.GenerateOutcomeCode.stop,
            "ZENCODE_DS4_GENERATE_MAX_TOKENS": DS4EngineABI.GenerateOutcomeCode.maxTokens,
            "ZENCODE_DS4_GENERATE_CANCELLED": DS4EngineABI.GenerateOutcomeCode.cancelled,
            "ZENCODE_DS4_GENERATE_CALLER_STOP": DS4EngineABI.GenerateOutcomeCode.callerStop,
            "ZENCODE_DS4_EMIT_CONTINUE": DS4EngineABI.EmitFlag.continue,
            "ZENCODE_DS4_EMIT_STOP": DS4EngineABI.EmitFlag.stop,
            "ZENCODE_DS4_EMIT_GREEDY": DS4EngineABI.EmitFlag.greedy,
            "ZENCODE_DS4_KV_SKIPPED_VISION": DS4EngineABI.kvSkippedVision,
            "ZENCODE_DS4_ERR_INVALID_ARGUMENT": DS4EngineABI.ErrorCode.invalidArgument,
            "ZENCODE_DS4_ERR_OUT_OF_MEMORY": DS4EngineABI.ErrorCode.outOfMemory,
            "ZENCODE_DS4_ERR_INVALID_OPTION": DS4EngineABI.ErrorCode.invalidOption,
            "ZENCODE_DS4_ERR_INSTANCE_LOCKED": DS4EngineABI.ErrorCode.instanceLocked,
            "ZENCODE_DS4_ERR_ENGINE_OPEN": DS4EngineABI.ErrorCode.engineOpen,
            "ZENCODE_DS4_ERR_SESSION": DS4EngineABI.ErrorCode.session,
            "ZENCODE_DS4_ERR_DECODE": DS4EngineABI.ErrorCode.decode,
            "ZENCODE_DS4_ERR_UNSUPPORTED": DS4EngineABI.ErrorCode.unsupported,
            "ZENCODE_DS4_ERR_VISION": DS4EngineABI.ErrorCode.vision,
            "ZENCODE_DS4_ERR_IO": DS4EngineABI.ErrorCode.io,
            "ZENCODE_DS4_ERR_KV_INVALID": DS4EngineABI.ErrorCode.kvInvalid,
            "ZENCODE_DS4_ERR_KV_INCOMPATIBLE": DS4EngineABI.ErrorCode.kvIncompatible,
            "ZENCODE_DS4_ERR_TENSOR_PARALLEL": DS4EngineABI.ErrorCode.tensorParallel,
            "ZENCODE_DS4_ERR_BUSY": DS4EngineABI.ErrorCode.busy,
            "ZENCODE_DS4_THINK_NONE": DS4EngineABI.ThinkMode.none,
            "ZENCODE_DS4_THINK_HIGH": DS4EngineABI.ThinkMode.high,
            "ZENCODE_DS4_THINK_MAX": DS4EngineABI.ThinkMode.max,
            "ZENCODE_DS4_THINK_LOW": DS4EngineABI.ThinkMode.low,
            "ZENCODE_DS4_THINK_MEDIUM": DS4EngineABI.ThinkMode.medium,
            "ZENCODE_DS4_THINK_LEVEL_BASE": DS4EngineABI.ThinkMode.levelBase,
            "ZENCODE_DS4_THINK_LEVEL_MAX": DS4EngineABI.ThinkMode.levelMax,
            "ZENCODE_DS4_TOOL_SYNTAX_DSML": DS4EngineABI.ToolSyntax.dsml,
            "ZENCODE_DS4_TOOL_SYNTAX_DSML41": DS4EngineABI.ToolSyntax.dsml41,
            "ZENCODE_DS4_TOOL_SYNTAX_GLM": DS4EngineABI.ToolSyntax.glm,
            "ZENCODE_DS4_TOOL_SYNTAX_QWEN": DS4EngineABI.ToolSyntax.qwen,
            "ZENCODE_DS4_STAT_PROMPT_TOKENS": DS4EngineABI.StatID.promptTokens,
            "ZENCODE_DS4_STAT_CACHED_TOKENS": DS4EngineABI.StatID.cachedTokens,
            "ZENCODE_DS4_STAT_EVALUATED_TOKENS": DS4EngineABI.StatID.evaluatedTokens,
            "ZENCODE_DS4_STAT_GENERATED_TOKENS": DS4EngineABI.StatID.generatedTokens,
            "ZENCODE_DS4_STAT_PREFILL_SECONDS": DS4EngineABI.StatID.prefillSeconds,
            "ZENCODE_DS4_STAT_GENERATION_SECONDS": DS4EngineABI.StatID.generationSeconds,
            "ZENCODE_DS4_STAT_PREFILL_TOKENS_PER_SECOND": DS4EngineABI.StatID.prefillTokensPerSecond,
            "ZENCODE_DS4_STAT_GENERATION_TOKENS_PER_SECOND": DS4EngineABI.StatID.generationTokensPerSecond,
            "ZENCODE_DS4_STAT_SESSION_POS": DS4EngineABI.StatID.sessionPosition,
            "ZENCODE_DS4_STAT_SESSION_CTX": DS4EngineABI.StatID.sessionContext,
            "ZENCODE_DS4_STAT_COUNT": DS4EngineABI.StatID.count
        ]

        #expect(defined == mirrored)
    }

    // MARK: Error mapping

    @Test
    func everyErrorCodeMapsToADedicatedCase() {
        let cases: [(Int32, DS4EngineError)] = [
            (-1, .invalidArgument("m")), (-2, .outOfMemory("m")), (-3, .invalidOption("m")),
            (-4, .instanceLocked("m")), (-5, .openFailed("m")), (-6, .sessionFailed("m")),
            (-7, .decodeFailed("m")), (-8, .unsupported("m")), (-9, .vision("m")), (-10, .io("m")),
            (-11, .kvInvalid("m")), (-12, .kvIncompatible("m")), (-13, .tensorParallel("m")), (-14, .busy("m"))
        ]
        for (code, expected) in cases {
            #expect(DS4EngineError(code: code, message: "m") == expected)
        }
        #expect(DS4EngineError(code: -6, message: "") == .sessionFailed("unknown DS4 engine error (code -6)"))
    }

    // MARK: Loader

    @Test
    func missingLibraryIsUnavailableWithTheBuildCommand() throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(DS4EngineABI.libraryFileName)

        let error = #expect(throws: DS4EngineError.self) {
            _ = try DS4EngineLibrary.load(at: url, buildHint: DS4LibraryFixtures.hint)
        }

        guard case .libraryUnavailable(let reason, let hint) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.contains(url.path))
        #expect(hint == DS4LibraryFixtures.hint)
    }

    @Test(.enabled(if: DS4LibraryFixtures.compilerPath != nil, "needs a C compiler"), arguments: [1, 99])
    func staleABIVersionIsRejected(foundVersion: Int32) throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Version 1 libraries lack zencode_ds4_tokens_push: they must be
        // reported as obsolete (rebuild), not fail later on a missing symbol.
        let url = try DS4LibraryFixtures.buildLibrary(
            source: "#include <stdint.h>\nint32_t zencode_ds4_abi_version(void) { return \(foundVersion); }\n",
            in: directory
        )

        #expect(throws: DS4EngineError.abiMismatch(
            found: foundVersion, expected: DS4EngineABI.expectedVersion, hint: DS4LibraryFixtures.hint
        )) {
            _ = try DS4EngineLibrary.load(at: url, buildHint: DS4LibraryFixtures.hint)
        }
    }
}

// MARK: - Real library

/// Runs against a built libzencode-ds4 (ZENCODE_DS4_ENGINE_LIBRARY) without
/// loading a model. Serialized: it changes DS4_LOCK_FILE for the process.
@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["ZENCODE_DS4_ENGINE_LIBRARY"] != nil, "ZENCODE_DS4_ENGINE_LIBRARY not set")
)
struct DS4EngineLibraryRealTests {
    private static var libraryURL: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["ZENCODE_DS4_ENGINE_LIBRARY"] ?? "")
    }

    @Test
    func loadsEverySymbolAndParsesThinkLevels() throws {
        let library = try DS4EngineLibrary.load(at: Self.libraryURL, buildHint: DS4LibraryFixtures.hint)

        #expect(library.abiVersion == DS4EngineABI.expectedVersion)
        #expect(library.thinkMode(parseLevel: "50") == 1050)
        #expect(library.thinkMode(parseLevel: "0") == DS4EngineABI.ThinkMode.levelBase)
        #expect(library.thinkMode(parseLevel: "100") == 1100)
        #expect(library.thinkMode(parseLevel: "101") == nil)
        #expect(library.thinkMode(parseLevel: "high") == nil)
        let again = try DS4EngineLibrary.load(at: Self.libraryURL, buildHint: DS4LibraryFixtures.hint)
        #expect(again === library)
    }
}
