//
//  DS4EngineBuilderTests.swift
//  ZenCODE
//
//  The builder is exercised through its process and library seams: no unit test
//  starts a real build. `realBuildFromDS4Checkout` runs the real script only when
//  `ZENCODE_TEST_DS4_ROOT` points at a DS4 checkout.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private final class LineCollector: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    var lines: [String] {
        storage.withLock { $0 }
    }
}

/// Fake process runner: records each call and delegates the behaviour to `handler`.
private final class FakeProcessRunner: DS4EngineProcessRunning {
    struct Call: Sendable, Equatable {
        let executable: URL
        let arguments: [String]
    }

    typealias Handler = @Sendable (Call, @Sendable (String) -> Void) throws -> Int32

    private let handler: Handler
    private let recorded = Mutex<[Call]>([])

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var calls: [Call] {
        recorded.withLock { $0 }
    }

    func run(
        executable: URL,
        arguments: [String],
        output: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
        let call = Call(executable: executable, arguments: arguments)
        recorded.withLock { $0.append(call) }
        return try handler(call, output)
    }
}

private struct FakeVerifier: DS4EngineLibraryVerifying {
    let version: Int32
    func abiVersion(ofLibraryAt url: URL) throws -> Int32 { version }
}

/// Writes the library where `--output` points, like the real script does.
private func succeedingHandler(
    lines: [String] = []
) -> FakeProcessRunner.Handler {
    { call, output in
        for line in lines {
            output(line)
        }
        let outputPath = try #require(call.arguments.last)
        let url = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("library".utf8).write(to: url)
        return 0
    }
}

private func defaultBackend() -> AgentDS4RuntimeBackend {
    #if os(macOS)
    .metal
    #else
    .cpu
    #endif
}

@Suite
struct DS4EngineBuilderTests {
    private func request(
        _ fixture: DS4EngineBuildFixture,
        backend: AgentDS4RuntimeBackend = defaultBackend(),
        cudaArch: String? = nil,
        rocmArch: String? = nil
    ) -> DS4EngineBuildRequest {
        DS4EngineBuildRequest(
            rootDirectory: fixture.rootDirectory,
            backend: backend,
            cudaArch: cudaArch,
            rocmArch: rocmArch,
            supportDirectory: fixture.supportDirectory
        )
    }

    // MARK: Successful build

    @Test
    func buildExtractsSourcesRunsTheScriptAndReturnsTheExpectedLibrary() async throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let runner = FakeProcessRunner(handler: succeedingHandler(lines: ["==> compiling", "done"]))
        let builder = DS4EngineBuilder(
            processRunner: runner,
            verifier: FakeVerifier(version: DS4EngineABI.expectedVersion)
        )
        let collector = LineCollector()
        let request = request(fixture)

        let library = try await builder.build(request) { collector.append($0) }

        let expected = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: request.backend,
            supportDirectory: fixture.supportDirectory
        )
        #expect(library == expected)
        #expect(FileManager.default.fileExists(atPath: library.path))

        let shimDirectory = DS4EngineLibraryLocator.shimDirectory(supportDirectory: fixture.supportDirectory)
        let call = try #require(runner.calls.first)
        #expect(runner.calls.count == 1)
        #expect(call.executable.path == "/bin/bash")
        #expect(call.arguments == [
            shimDirectory.appendingPathComponent("build-ds4-engine.sh").path,
            "--root", fixture.rootDirectory,
            "--backend", request.backend.rawValue,
            "--shim", shimDirectory.path,
            "--output", expected.path
        ])

        let lines = collector.lines
        #expect(lines.contains("==> compiling"))
        #expect(lines.contains("done"))
        #expect(lines.first?.hasPrefix("==> Writing the DS4 engine sources") == true)
        #expect(lines.last?.hasPrefix("==> DS4 engine ready") == true)
    }

    @Test
    func scriptArgumentsCarryTheEffectiveArchitecture() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        let shim = URL(fileURLWithPath: "/support/ds4/shim")
        let output = URL(fileURLWithPath: "/support/ds4/engines/x/lib.so")

        func arguments(_ backend: AgentDS4RuntimeBackend, cuda: String?, rocm: String?) -> [String] {
            DS4EngineBuilder.scriptArguments(
                for: DS4EngineBuildRequest(
                    rootDirectory: "/ds4",
                    backend: backend,
                    cudaArch: cuda,
                    rocmArch: rocm,
                    supportDirectory: fixture.supportDirectory
                ),
                rootDirectory: "/ds4",
                shimDirectory: shim,
                outputURL: output
            )
        }
        let tail = ["--shim", "/support/ds4/shim", "--output", "/support/ds4/engines/x/lib.so"]

        #expect(arguments(.cuda, cuda: nil, rocm: "gfx1100")
            == ["--root", "/ds4", "--backend", "cuda", "--cuda-arch", "native"] + tail)
        #expect(arguments(.cuda, cuda: "sm_120", rocm: nil)
            == ["--root", "/ds4", "--backend", "cuda", "--cuda-arch", "sm_120"] + tail)
        #expect(arguments(.rocm, cuda: "sm_120", rocm: nil)
            == ["--root", "/ds4", "--backend", "rocm", "--rocm-arch", "gfx1151"] + tail)
        #expect(arguments(.rocm, cuda: nil, rocm: "gfx1100")
            == ["--root", "/ds4", "--backend", "rocm", "--rocm-arch", "gfx1100"] + tail)
        #expect(arguments(.cpu, cuda: "sm_120", rocm: "gfx1100")
            == ["--root", "/ds4", "--backend", "cpu"] + tail)
        #expect(arguments(.metal, cuda: nil, rocm: nil)
            == ["--root", "/ds4", "--backend", "metal"] + tail)
    }

    // MARK: Failures

    @Test
    func nonZeroExitReportsTheManualCommand() async throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let builder = DS4EngineBuilder(
            processRunner: FakeProcessRunner { _, output in
                output("error: nvcc not found")
                return 3
            },
            verifier: FakeVerifier(version: DS4EngineABI.expectedVersion)
        )
        let request = request(fixture)
        let manual = DS4EngineBuilder.manualCommand(for: request)

        do {
            _ = try await builder.build(request) { _ in }
            Issue.record("the build should have failed")
        } catch let error as DS4EngineBuildError {
            #expect(error == .buildFailed(exitCode: 3, manualCommand: manual))
            #expect(error.localizedDescription.contains(manual))
            #expect(error.localizedDescription.contains("exit status 3"))
        }
    }

    @Test
    func anInvalidArchitectureFailsBeforeAnyProcessRuns() async throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let runner = FakeProcessRunner(handler: succeedingHandler())
        let builder = DS4EngineBuilder(
            processRunner: runner,
            verifier: FakeVerifier(version: DS4EngineABI.expectedVersion)
        )
        // The architecture is validated before the platform, so this holds everywhere.
        await #expect(throws: DS4EngineBuildError.invalidArchitecture("sm_90; rm -rf /")) {
            _ = try await builder.build(request(fixture, backend: .cuda, cudaArch: "sm_90; rm -rf /")) { _ in }
        }
        await #expect(throws: DS4EngineBuildError.invalidArchitecture("gfx 11")) {
            _ = try await builder.build(request(fixture, backend: .rocm, rocmArch: "gfx 11")) { _ in }
        }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func anABIVersionMismatchIsAnError() async throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }

        let found = DS4EngineABI.expectedVersion + 1
        let builder = DS4EngineBuilder(
            processRunner: FakeProcessRunner(handler: succeedingHandler()),
            verifier: FakeVerifier(version: found)
        )
        let expected = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: fixture.rootDirectory,
            backend: defaultBackend(),
            supportDirectory: fixture.supportDirectory
        )
        await #expect(throws: DS4EngineBuildError.abiVersionMismatch(
            path: expected.path,
            found: found,
            expected: DS4EngineABI.expectedVersion
        )) {
            _ = try await builder.build(request(fixture)) { _ in }
        }
    }

    // MARK: Manual command

    @Test
    func manualCommandQuotesPathsWithSpacesAndQuotes() {
        let request = DS4EngineBuildRequest(
            rootDirectory: "/Users/me/my ds4/it's",
            backend: .cpu,
            cudaArch: nil,
            rocmArch: nil,
            supportDirectory: URL(fileURLWithPath: "/tmp/support dir")
        )
        let command = DS4EngineBuilder.manualCommand(for: request)
        #expect(command.hasPrefix("/bin/bash '/tmp/support dir/ds4/shim/build-ds4-engine.sh' --root "))
        #expect(command.contains("'/Users/me/my ds4/it'\\''s'"))
        #expect(command.contains("--backend cpu"))
        #expect(command.contains("--output '/tmp/support dir/ds4/engines/cpu-"))
    }

    // MARK: Output splitting

    @Test
    func lineSplitterReassemblesLinesAcrossChunks() {
        var splitter = DS4EngineLineSplitter()
        #expect(splitter.append(Data("first\nsec".utf8)) == ["first"])
        #expect(splitter.append(Data("ond\r\nthird\n\nfourth".utf8)) == ["second", "third", ""])
        #expect(splitter.finish() == ["fourth"])
        #expect(splitter.finish().isEmpty)
    }

    // MARK: Real build (opt-in)

    /// Runs the real script and a real dlopen against a DS4 checkout:
    /// `ZENCODE_TEST_DS4_ROOT=~/Projects/ds4 swift test --filter DS4EngineBuilderTests/realBuild`.
    /// `ZENCODE_TEST_DS4_BACKEND` selects the backend (default: metal on macOS, cpu elsewhere).
    /// No model is loaded; the support directory is a temporary directory.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ZENCODE_TEST_DS4_ROOT"] != nil))
    func realBuildFromDS4Checkout() async throws {
        let environment = ProcessInfo.processInfo.environment
        let root = try #require(environment["ZENCODE_TEST_DS4_ROOT"])
        let backend = environment["ZENCODE_TEST_DS4_BACKEND"].flatMap(AgentDS4RuntimeBackend.init(rawValue:))
            ?? defaultBackend()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: support) }

        let request = DS4EngineBuildRequest(
            rootDirectory: (root as NSString).expandingTildeInPath,
            backend: backend,
            cudaArch: environment["ZENCODE_TEST_DS4_CUDA_ARCH"],
            rocmArch: environment["ZENCODE_TEST_DS4_ROCM_ARCH"],
            supportDirectory: support
        )
        let collector = LineCollector()
        let library = try await DS4EngineBuilder().build(request) { line in
            collector.append(line)
            print(line)
        }

        #expect(FileManager.default.fileExists(atPath: library.path))
        #expect(library.path.hasPrefix(support.path))
        #expect(try DS4EngineDynamicLibraryVerifier().abiVersion(ofLibraryAt: library) == DS4EngineABI.expectedVersion)
        #expect(DS4EngineLibraryLocator.status(
            rootDirectory: request.rootDirectory,
            backend: backend,
            arch: backend == .cuda ? request.cudaArch : request.rocmArch,
            supportDirectory: support
        ) == .built(library))

        let metadata = try #require(DS4EngineLibraryLocator.buildMetadata(inDirectory: library.deletingLastPathComponent()))
        #expect(library.deletingLastPathComponent().lastPathComponent == "\(backend.rawValue)-\(try #require(metadata.hash))")
        #expect(metadata.abiVersion == DS4EngineABI.expectedVersion)
        #expect(collector.lines.contains { $0.hasPrefix("==> Done:") })
    }
}
