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

    @Test
    func libraryErrorsCarryTheBuildHint() {
        let errors: [DS4EngineError] = [
            .libraryUnavailable(reason: "missing", hint: DS4LibraryFixtures.hint),
            .abiMismatch(found: 1, expected: 2, hint: DS4LibraryFixtures.hint),
            .missingSymbol("zencode_ds4_stat", hint: DS4LibraryFixtures.hint)
        ]
        for error in errors {
            #expect(error.isLibraryUnavailable)
            #expect(error.buildHint == DS4LibraryFixtures.hint)
            #expect(error.localizedDescription.hasSuffix("Rebuild it with: \(DS4LibraryFixtures.hint)"))
        }
        #expect(!DS4EngineError.openFailed("x").isLibraryUnavailable)
        #expect(DS4EngineError.instanceLocked("pid 7").localizedDescription.contains("another DS4 process is using this model"))
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

    @Test
    func nonLibraryFileIsUnavailable() throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(DS4EngineABI.libraryFileName)
        try Data("not a dynamic library".utf8).write(to: url)

        let error = #expect(throws: DS4EngineError.self) {
            _ = try DS4EngineLibrary.load(at: url, buildHint: DS4LibraryFixtures.hint)
        }

        guard case .libraryUnavailable(let reason, _) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(reason.contains("cannot load"))
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

    @Test(.enabled(if: DS4LibraryFixtures.compilerPath != nil, "needs a C compiler"))
    func missingSymbolIsRejected() throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try DS4LibraryFixtures.buildLibrary(
            source: "#include <stdint.h>\nint32_t zencode_ds4_abi_version(void) { return 2; }\n",
            in: directory
        )

        #expect(throws: DS4EngineError.missingSymbol("zencode_ds4_last_error", hint: DS4LibraryFixtures.hint)) {
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

    private static func configuration(model: URL) -> DS4EngineConfiguration {
        DS4EngineConfiguration(
            libraryURL: libraryURL,
            options: [
                DS4EngineOption(key: "model_path", value: model.path),
                DS4EngineOption(key: "backend", value: "cpu")
            ],
            contextSize: 4096,
            sessionCapacity: 1,
            buildHint: DS4LibraryFixtures.hint
        )
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

    @Test
    func tokensPushAppendsTheExactIDsAndRejectsInvalidArguments() throws {
        let library = try DS4EngineLibrary.load(at: Self.libraryURL, buildHint: DS4LibraryFixtures.hint)
        let symbols = library.symbols
        let buffer = try #require(symbols.tokensNew())
        defer { symbols.tokensFree(buffer) }

        // No engine involved: the ids are stored as they are, in order.
        let ids: [Int32] = [7, 0, 151_644, 42, 42]
        for id in ids {
            #expect(symbols.tokensPush(buffer, id) == DS4EngineABI.ok)
        }
        #expect(symbols.tokensLen(buffer) == Int32(ids.count))
        for (index, id) in ids.enumerated() {
            #expect(symbols.tokensGet(buffer, Int32(index)) == id)
        }

        // A NULL buffer and a negative id are invalid arguments and change nothing.
        #expect(symbols.tokensPush(nil, 1) == DS4EngineABI.ErrorCode.invalidArgument)
        #expect(symbols.tokensPush(buffer, -1) == DS4EngineABI.ErrorCode.invalidArgument)
        #expect(String(cString: symbols.lastError()!).contains("negative"))
        #expect(symbols.tokensLen(buffer) == Int32(ids.count))
    }

    @Test
    func missingModelPathFailsWithAnExplicitError() async throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = directory.appendingPathComponent("missing.gguf")
        let registry = DS4EngineRegistry(factory: DS4EngineRegistry.nativeFactory)

        let error = await #expect(throws: DS4EngineError.self) {
            _ = try await registry.engine(for: Self.configuration(model: model))
        }

        guard case .invalidOption(let message) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(message.contains("model_path"))
        #expect(message.contains(model.path))
        #expect(await registry.currentIdentity == nil)
    }

    @Test
    func heldInstanceLockFailsWithAnExplicitError() async throws {
        let directory = try DS4LibraryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Passes the shim's GGUF pre-check (regular file >= 32 bytes); the
        // held lock stops the open before ds4_engine_open reads it.
        let model = directory.appendingPathComponent("model.gguf")
        try Data(repeating: 0, count: 64).write(to: model)
        let lockURL = directory.appendingPathComponent("ds4.lock")
        try Data("4242\n".utf8).write(to: lockURL)

        let descriptor = open(lockURL.path, O_RDWR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        // Must hold: otherwise DS4 would try to load the fake model.
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)

        let previous = ProcessInfo.processInfo.environment["DS4_LOCK_FILE"]
        setenv("DS4_LOCK_FILE", lockURL.path, 1)
        defer {
            if let previous {
                setenv("DS4_LOCK_FILE", previous, 1)
            } else {
                unsetenv("DS4_LOCK_FILE")
            }
        }

        let error = await #expect(throws: DS4EngineError.self) {
            _ = try await DS4NativeEngine.open(configuration: Self.configuration(model: model))
        }

        guard case .instanceLocked(let message) = error else {
            Issue.record("unexpected error \(String(describing: error))")
            return
        }
        #expect(message.contains("another ds4 process is already running"))
        #expect(message.contains("4242"))
        #expect(error?.localizedDescription.contains("another DS4 process is using this model") == true)
    }
}
