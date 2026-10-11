//
//  DS4ServerSupervisorTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

#if os(macOS) || os(Linux)
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

@Suite("DS4ServerSupervisor", .serialized, .timeLimit(.minutes(2)))
struct DS4ServerSupervisorTests {
    @Test
    func missingBinaryIsReportedBeforeAnyChildStarts() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let manifest = try fixture.manifest(model: true)
        let missing = fixture.root.appendingPathComponent("missing-ds4")
        let supervisor = DS4ServerSupervisor(
            manifest: manifest,
            executableURL: missing,
            modelAlias: "fixture-model",
            readinessTimeout: .milliseconds(250)
        )

        await #expect(throws: DS4ServerSupervisorError.executableNotFound(missing.path)) {
            try await supervisor.start()
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func crashSurfacesExitCodeAndStderrAndCanBeRetried() async throws {
        let fixture = try Fixture.make(mode: "crash")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .seconds(2))

        do {
            _ = try await supervisor.start()
            Issue.record("The crashing fixture unexpectedly became ready.")
        } catch let error as DS4ServerSupervisorError {
            guard case let .processExited(exitCode, diagnostics) = error else {
                Issue.record("Unexpected supervisor error: \(error)")
                return
            }
            #expect(exitCode == 23)
            #expect(diagnostics.contains("fixture crash"))
        }
        #expect(!(await supervisor.isRunning))
        // The failed launch is not terminal: the caller can use the same
        // owner again after replacing the fixture executable path.
        await supervisor.shutdown()
        await supervisor.shutdown()
    }

    @Test
    func readinessTimeoutStopsOnlyTheOwnedChild() async throws {
        let fixture = try Fixture.make(mode: "timeout")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .milliseconds(350))

        do {
            _ = try await supervisor.start()
            Issue.record("The non-HTTP fixture unexpectedly became ready.")
        } catch let error as DS4ServerSupervisorError {
            guard case let .readinessTimedOut(_, diagnostics) = error else {
                Issue.record("Unexpected supervisor error: \(error)")
                return
            }
            #expect(diagnostics.isEmpty)
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.stop()
        await supervisor.stop()
        await supervisor.shutdown()
    }

    @Test
    func explicitPortCollisionIsRejectedWithoutLaunchingAChild() async throws {
        let blocker = try PortBlocker()
        defer { blocker.close() }
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }
        let manifest = try fixture.manifest(model: true)
        let supervisor = DS4ServerSupervisor(
            manifest: manifest,
            executableURL: fixture.executable,
            modelAlias: "fixture-model",
            port: blocker.port,
            readinessTimeout: .milliseconds(300)
        )

        await #expect(throws: DS4ServerSupervisorError.portUnavailable(blocker.port)) {
            try await supervisor.start()
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func wrongAdvertisedAliasFailsReadinessAndReapsOwnedChild() async throws {
        let fixture = try Fixture.make(mode: "wrong-alias")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .seconds(2))

        await #expect(
            throws: DS4ServerSupervisorError.modelAliasMismatch(
                expected: "fixture-model",
                advertised: ["not-the-requested-model"]
            )
        ) {
            try await supervisor.start()
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func readinessUsesDirectArgvSingleFlightAndIdempotentLifecycle() async throws {
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .seconds(2))

        async let first = supervisor.start()
        async let second = supervisor.start()
        let firstEndpoint = try await first
        let secondEndpoint = try await second

        #expect(firstEndpoint == secondEndpoint)
        #expect(firstEndpoint.modelID == "fixture-model")
        #expect(firstEndpoint.baseURL.path == "/v1")
        #expect(firstEndpoint.modelsURL.path == "/v1/models")
        #expect(!(await supervisor.launchArguments.contains("-server")))
        #expect(await supervisor.launchArguments.contains("--ctx"))
        #expect(await supervisor.launchArguments.contains("1024"))
        #expect(await supervisor.launchArguments.contains("--power"))
        #expect(await supervisor.launchArguments.contains("100"))
        #expect(!(await supervisor.launchArguments.contains("--mtp")))
        #expect(await supervisor.launchArguments.contains("--host"))
        #expect(await supervisor.launchArguments.contains("127.0.0.1"))
        #expect(await supervisor.launchArguments.contains("-m"))
        #expect(await supervisor.launchArguments.contains(fixture.model.path))
        let startedAgain = try await supervisor.start()
        #expect(startedAgain == firstEndpoint)

        await supervisor.stop()
        await supervisor.stop()
        #expect(!(await supervisor.isRunning))

        // A stop is reusable, while shutdown is a permanent fence.
        let restarted = try await supervisor.start()
        #expect(restarted.modelID == "fixture-model")
        await supervisor.shutdown()
        await supervisor.shutdown()
        #expect(!(await supervisor.isRunning))
        await #expect(throws: DS4ServerSupervisorError.shutdown) {
            try await supervisor.start()
        }
    }

    @Test
    func readinessUsesMTPAndConfiguredPowerArguments() async throws {
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(
            timeout: .seconds(2),
            mtp: true,
            power: 37
        )

        _ = try await supervisor.start()
        let arguments = await supervisor.launchArguments
        #expect(arguments.contains("--mtp"))
        #expect(arguments.contains("--power"))
        #expect(arguments.contains("37"))
        await supervisor.shutdown()
    }

    @Test
    func ssdStreamingArgumentsAreGatedAndAvailableAfterReenable() async throws {
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }

        let off = try fixture.supervisor(
            timeout: .seconds(2),
            ssdStreaming: false,
            ssdStreamingCacheExperts: 8,
            ssdStreamingCacheBytes: 4_000_000_000,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true
        )
        _ = try await off.start()
        let offArguments = await off.launchArguments
        #expect(!offArguments.contains("--ssd-streaming"))
        #expect(!offArguments.contains("--ssd-streaming-cold"))
        #expect(!offArguments.contains("--ssd-streaming-cache-experts"))
        #expect(!offArguments.contains("--ssd-streaming-preload-experts"))
        await off.shutdown()

        let on = try fixture.supervisor(
            timeout: .seconds(2),
            ssdStreaming: true,
            ssdStreamingCacheExperts: 8,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true
        )
        _ = try await on.start()
        let onArguments = await on.launchArguments
        #expect(onArguments.contains("--ssd-streaming"))
        #expect(onArguments.contains("--ssd-streaming-cold"))
        #expect(onArguments.contains("--ssd-streaming-cache-experts"))
        #expect(onArguments.contains("8"))
        #expect(onArguments.contains("--ssd-streaming-preload-experts"))
        #expect(onArguments.contains("2"))
        await on.shutdown()

        let onByteCache = try fixture.supervisor(
            timeout: .seconds(2),
            ssdStreaming: true,
            ssdStreamingCacheBytes: 4_000_000_000
        )
        _ = try await onByteCache.start()
        let onByteCacheArguments = await onByteCache.launchArguments
        #expect(onByteCacheArguments.contains("--ssd-streaming-cache-experts"))
        #expect(onByteCacheArguments.contains("4GB"))
        await onByteCache.shutdown()
    }

    @Test
    func cancellingStartupFencesLateChildCreation() async throws {
        let fixture = try Fixture.make(mode: "delayed")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .seconds(5))

        let startup = Task {
            try await supervisor.start()
        }
        try await Task.sleep(for: .milliseconds(80))
        startup.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await startup.value
        }
        try await Task.sleep(for: .milliseconds(120))
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func cancellingOneSharedWaiterDoesNotCancelTheRemainingStartup() async throws {
        let fixture = try Fixture.make(mode: "delayed")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(timeout: .seconds(5))

        let cancelledWaiter = Task {
            try await supervisor.start()
        }
        try await Task.sleep(for: .milliseconds(80))
        let remainingWaiter = Task {
            try await supervisor.start()
        }
        try await Task.sleep(for: .milliseconds(80))

        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }
        let endpoint = try await remainingWaiter.value
        #expect(endpoint.modelID == "fixture-model")
        #expect(await supervisor.isRunning)
        await supervisor.shutdown()
    }

    @Test
    func oversizedSingleReadChunkReturnsBoundedErrorWithoutUnderflow() async throws {
        let fixture = try Fixture.make(mode: "oversized")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(
            timeout: .seconds(2),
            maximumBodyBytes: 8
        )

        await #expect(throws: DS4ServerSupervisorError.readinessResponseTooLarge(8)) {
            _ = try await supervisor.start()
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func reservedArgumentsCannotOverrideLoopbackPortModelOrWorkingDirectory() async throws {
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }
        let supervisor = try fixture.supervisor(
            timeout: .seconds(2),
            additionalArguments: ["--host=0.0.0.0", "--model", "/tmp/outside.gguf", "--chdir=/tmp"]
        )

        await #expect(throws: DS4ServerSupervisorError.reservedArgument("--host=0.0.0.0")) {
            _ = try await supervisor.start()
        }
        #expect(!(await supervisor.isRunning))
        await supervisor.shutdown()
    }

    @Test
    func reservedMTPAndPowerArgumentsCannotBeOverridden() async throws {
        let fixture = try Fixture.make(mode: "ready")
        defer { fixture.remove() }

        for argument in ["--mtp", "--power", "--power=50"] {
            let supervisor = try fixture.supervisor(
                timeout: .seconds(2),
                additionalArguments: [argument]
            )
            await #expect(throws: DS4ServerSupervisorError.reservedArgument(argument)) {
                _ = try await supervisor.start()
            }
            await supervisor.shutdown()
        }
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let model: URL

        static func make(mode: String = "ready") throws -> Fixture {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("zencode-ds4-supervisor-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let executable = root.appendingPathComponent("fixture.py")
            let model = root.appendingPathComponent("models/model with spaces.gguf")
            try fileManager.createDirectory(
                at: model.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: model)
            try Self.pythonFixture(mode: mode).write(to: executable, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return Fixture(root: root, executable: executable, model: model)
        }

        func manifest(
            model: Bool,
            contextWindow: Int = 1024,
            mtp: Bool = false,
            power: Int = 100,
            ssdStreaming: Bool = false,
            ssdStreamingCacheExperts: UInt32? = nil,
            ssdStreamingCacheBytes: UInt64? = nil,
            ssdStreamingPreloadExperts: UInt32? = nil,
            ssdStreamingCold: Bool = false
        ) throws -> AgentDS4RuntimeManifest {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                modelRelativePath: model ? "models/model with spaces.gguf" : nil,
                contextWindow: contextWindow,
                ssdStreaming: ssdStreaming,
                ssdStreamingCacheExperts: ssdStreamingCacheExperts,
                ssdStreamingCacheBytes: ssdStreamingCacheBytes,
                ssdStreamingPreloadExperts: ssdStreamingPreloadExperts,
                ssdStreamingCold: ssdStreamingCold,
                mtp: mtp,
                power: power
            )
        }

        func supervisor(
            timeout: Duration,
            maximumBodyBytes: Int = DS4ServerSupervisor.defaultMaximumReadinessBodyBytes,
            additionalArguments: [String] = [],
            mtp: Bool = false,
            power: Int = 100,
            ssdStreaming: Bool = false,
            ssdStreamingCacheExperts: UInt32? = nil,
            ssdStreamingCacheBytes: UInt64? = nil,
            ssdStreamingPreloadExperts: UInt32? = nil,
            ssdStreamingCold: Bool = false
        ) throws -> DS4ServerSupervisor {
            DS4ServerSupervisor(
                manifest: try manifest(
                    model: true,
                    mtp: mtp,
                    power: power,
                    ssdStreaming: ssdStreaming,
                    ssdStreamingCacheExperts: ssdStreamingCacheExperts,
                    ssdStreamingCacheBytes: ssdStreamingCacheBytes,
                    ssdStreamingPreloadExperts: ssdStreamingPreloadExperts,
                    ssdStreamingCold: ssdStreamingCold
                ),
                executableURL: executable,
                modelAlias: "fixture-model",
                readinessTimeout: timeout,
                readinessPollInterval: .milliseconds(25),
                maximumReadinessBodyBytes: maximumBodyBytes,
                terminationGracePeriod: 0.05,
                additionalArguments: additionalArguments
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        private static func pythonFixture(mode: String) -> String {
            """
            #!/usr/bin/env python3
            import json
            import signal
            import socket
            import sys
            import time

            mode = "\(mode)"
            args = sys.argv[1:]
            def value(flag, fallback=None):
                try:
                    return args[args.index(flag) + 1]
                except (ValueError, IndexError):
                    return fallback

            if mode == "crash":
                sys.stderr.write("fixture crash\\n")
                sys.stderr.flush()
                raise SystemExit(23)
            if mode == "delayed":
                time.sleep(1.0)
            if mode == "timeout":
                time.sleep(30.0)

            host = value("--host", "127.0.0.1")
            port = int(value("--port", "0"))
            advertised = "not-the-requested-model" if mode == "wrong-alias" else "fixture-model"
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind((host, port))
            server.listen(8)
            signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
            while True:
                connection, _ = server.accept()
                try:
                    request = connection.recv(4096)
                    if b"GET /v1/models" in request:
                        body = (b"x" * 64) if mode == "oversized" else json.dumps({"data": [{"id": advertised}]}).encode("utf-8")
                        response = b"HTTP/1.1 200 OK\\r\\nContent-Type: application/json\\r\\nContent-Length: " + str(len(body)).encode() + b"\\r\\nConnection: close\\r\\n\\r\\n" + body
                    else:
                        body = b"{}"
                        response = b"HTTP/1.1 404 Not Found\\r\\nContent-Length: 2\\r\\nConnection: close\\r\\n\\r\\n{}"
                    connection.sendall(response)
                finally:
                    connection.close()
            """
        }
    }

    private final class PortBlocker: @unchecked Sendable {
        let fileDescriptor: Int32
        let port: Int

        init() throws {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw POSIXTestError.socket }
            var address = sockaddr_in()
#if os(macOS)
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
#endif
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = 0
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                DarwinOrGlibcTest.close(descriptor)
                throw POSIXTestError.bind
            }
            guard listen(descriptor, 1) == 0 else {
                DarwinOrGlibcTest.close(descriptor)
                throw POSIXTestError.bind
            }
            var assigned = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let assignedResult = withUnsafeMutablePointer(to: &assigned) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard assignedResult == 0 else {
                DarwinOrGlibcTest.close(descriptor)
                throw POSIXTestError.bind
            }
            self.fileDescriptor = descriptor
            self.port = Int(UInt16(bigEndian: assigned.sin_port))
        }

        func close() {
            DarwinOrGlibcTest.close(fileDescriptor)
        }
    }

    private enum POSIXTestError: Error { case socket, bind }

#if os(macOS)
    private enum DarwinOrGlibcTest {
        static func close(_ descriptor: Int32) { _ = Darwin.close(descriptor) }
    }
#elseif os(Linux)
    private enum DarwinOrGlibcTest {
        static func close(_ descriptor: Int32) { _ = Glibc.close(descriptor) }
    }
#endif
}
#endif
