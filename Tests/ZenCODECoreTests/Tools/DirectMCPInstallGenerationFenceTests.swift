#if os(macOS)
  import Dispatch
  import Darwin
  import FeatureMCPBridgeKit
  import Foundation
  import Synchronization
  import Testing
  import ToolCore
  @testable import ZenCODECore

  @Suite("Direct MCP install generation fence", .serialized, .timeLimit(.minutes(1)))
  struct DirectMCPInstallGenerationFenceTests {
    @Test
    func borrowedInstallDisconnectsPreviouslyPublishedOwnedBackend() async throws {
      let fixture = try MCPGenerationFixture()
      defer { fixture.removeFiles() }

      let runtime = DirectMCPToolRuntime()
      let borrowedExecutor = makeBorrowedExecutor()
      do {
        let ownedDescriptors = try await runtime.installExternalMCPServer(
          name: "race",
          configuration: fixture.configuration
        )
        #expect(ownedDescriptors.map(\.name) == ["race.owned"])
        #expect(await runtime.knownDescriptors().map(\.name) == ["race.owned"])

        let borrowedDescriptors = await runtime.installBorrowedExternalExecutor(
          name: "race",
          executor: borrowedExecutor,
          tools: [borrowedTool]
        )

        #expect(FileManager.default.fileExists(atPath: fixture.disconnectedURL.path))
        #expect(borrowedDescriptors.map(\.name) == ["race.borrowed"])
        #expect(await runtime.knownDescriptors().map(\.name) == ["race.borrowed"])
      } catch {
        await cleanup(runtime: runtime, borrowedExecutor: borrowedExecutor)
        throw error
      }
      await cleanup(runtime: runtime, borrowedExecutor: borrowedExecutor)
      #expect(FileManager.default.fileExists(atPath: fixture.exitedURL.path))
    }

    @Test
    func borrowedInstallSupersedesAnOwnedInstallSuspendedInToolLoading() async throws {
      let fixture = try MCPGenerationFixture(suspendToolList: true)
      defer { fixture.removeFiles() }

      let runtime = DirectMCPToolRuntime()
      let borrowedExecutor = makeBorrowedExecutor()
      let ownedInstall = Task {
        try await runtime.installExternalMCPServer(
          name: "race",
          configuration: fixture.configuration
        )
      }

      do {
        // The fixture writes this FIFO only after it has opened the release
        // FIFO, making the subsequent release an ordered IPC handshake.
        try await fixture.waitUntilToolListIsSuspended()
        let borrowedInstall = Task {
          await runtime.installBorrowedExternalExecutor(
            name: "race",
            executor: borrowedExecutor,
            tools: [borrowedTool]
          )
        }
        let borrowedDescriptors = await borrowedInstall.value
        try fixture.releaseToolList()

        do {
          _ = try await ownedInstall.value
          Issue.record("The superseded owned install unexpectedly succeeded.")
        } catch is MCPRuntimeInstallSupersededError {
          // Expected: the borrowed install advanced this family's generation.
        }

        #expect(borrowedDescriptors.map(\.name) == ["race.borrowed"])
        #expect(await runtime.knownDescriptors().map(\.name) == ["race.borrowed"])
      } catch {
        await cleanup(
          runtime: runtime,
          borrowedExecutor: borrowedExecutor,
          installTask: ownedInstall
        )
        throw error
      }
      await cleanup(
        runtime: runtime,
        borrowedExecutor: borrowedExecutor,
        installTask: ownedInstall
      )
      #expect(FileManager.default.fileExists(atPath: fixture.exitedURL.path))
    }

    private var borrowedTool: ToolDescriptor {
      ToolDescriptor(
        name: "borrowed",
        description: "current borrowed tool",
        inputSchema: #"{"type":"object"}"#
      )
    }

    private func makeBorrowedExecutor() -> RemoteMCPToolExecutor {
      RemoteMCPToolExecutor(
        configuration: MCPServerConfiguration(
          executablePath: "/usr/bin/false",
          arguments: [],
          environment: [:]
        ),
        toolNamePrefix: "race."
      )
    }

    private func cleanup(
      runtime: DirectMCPToolRuntime,
      borrowedExecutor: RemoteMCPToolExecutor,
      installTask: Task<[DirectToolDescriptor], Error>? = nil
    ) async {
      installTask?.cancel()
      if let installTask {
        _ = await installTask.result
      }
      await runtime.shutdown()
      await borrowedExecutor.disconnect()
    }
  }

  private final class MCPGenerationFixture: Sendable {
    private struct DescriptorState: Sendable {
      var started: Int32?
      var release: Int32?
    }
    let rootURL: URL
    let executableURL: URL
    let startedURL: URL
    let releaseURL: URL
    let disconnectedURL: URL
    let exitedURL: URL
    let configuration: MCPServerConfiguration
    /// Keeping both FIFOs open read/write prevents artificial EOF while Python
    /// moves between opening the pipe and waiting on it.
    private let descriptorState: Mutex<DescriptorState>

    init(suspendToolList: Bool = false) throws {
      let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("mcp-install-fence-\(UUID().uuidString)", isDirectory: true)
      let executableURL = rootURL.appendingPathComponent("mcp-fixture.py")
      let startedURL = rootURL.appendingPathComponent("tools-list-started")
      let releaseURL = rootURL.appendingPathComponent("tools-list-release")
      let disconnectedURL = rootURL.appendingPathComponent("disconnected")
      let exitedURL = rootURL.appendingPathComponent("exited")
      let configuration = MCPServerConfiguration(
        executablePath: "/usr/bin/python3",
        arguments: [
          executableURL.path, suspendToolList ? "suspended" : "normal", startedURL.path,
          releaseURL.path, disconnectedURL.path, exitedURL.path,
        ],
        environment: [:]
      )

      self.rootURL = rootURL
      self.executableURL = executableURL
      self.startedURL = startedURL
      self.releaseURL = releaseURL
      self.disconnectedURL = disconnectedURL
      self.exitedURL = exitedURL
      self.configuration = configuration
      self.descriptorState = Mutex(DescriptorState(started: nil, release: nil))

      var initialized = false
      var startedDescriptor: Int32?
      var releaseDescriptor: Int32?
      defer {
        if !initialized {
          // The descriptors are kept locally until both opens succeed and
          // ownership is transferred to descriptorState. In particular, a
          // failed second open must not rely on the still-empty Mutex.
          if let startedDescriptor {
            _ = close(startedDescriptor)
          }
          if let releaseDescriptor {
            _ = close(releaseDescriptor)
          }
          self.closePersistentDescriptors()
          try? FileManager.default.removeItem(at: rootURL)
        }
      }

      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      if suspendToolList {
        try Self.makeFIFO(at: startedURL)
        try Self.makeFIFO(at: releaseURL)
        startedDescriptor = try Self.openPersistentFIFO(at: startedURL)
        releaseDescriptor = try Self.openPersistentFIFO(at: releaseURL)
        descriptorState.withLock { state in
          state.started = startedDescriptor
          state.release = releaseDescriptor
        }
        // Ownership now belongs to descriptorState; prevent the local defer
        // from closing descriptors that were successfully published.
        startedDescriptor = nil
        releaseDescriptor = nil
      }
      try Self.source.write(to: executableURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
      initialized = true
    }

    func waitUntilToolListIsSuspended() async throws {
      let descriptor = try duplicateStartedDescriptor()
      let waiter = FIFOReadWaiter(descriptor: descriptor)
      try await withTaskCancellationHandler(
        operation: {
          try await waiter.wait()
        },
        onCancel: {
          waiter.cancel()
        })
    }

    func releaseToolList() throws {
      try descriptorState.withLock { state in
        guard let releaseDescriptor = state.release else { throw POSIXError(.EINVAL) }
        var byte: UInt8 = 1
        let written = write(releaseDescriptor, &byte, 1)
        guard written == 1 else {
          if written < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
          }
          throw POSIXError(.EIO)
        }
      }
    }

    func removeFiles() {
      closePersistentDescriptors()
      try? FileManager.default.removeItem(at: rootURL)
    }

    private func duplicateStartedDescriptor() throws -> Int32 {
      try descriptorState.withLock { state in
        guard let startedDescriptor = state.started else { throw POSIXError(.EINVAL) }
        let descriptor = dup(startedDescriptor)
        guard descriptor >= 0 else {
          throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
      }
    }

    private func closePersistentDescriptors() {
      let descriptors = descriptorState.withLock { state -> [Int32] in
        defer {
          state.started = nil
          state.release = nil
        }
        return [state.started, state.release].compactMap { $0 }
      }
      for descriptor in descriptors {
        _ = close(descriptor)
      }
    }

    private static let source = #"""
      #!/usr/bin/python3
      import atexit, json, os, signal, sys
      mode, started, release, disconnected, exited = sys.argv[1:]
      def touch(path):
          with open(path, "w"): pass
      def stopped(signum, frame):
          touch(disconnected)
          raise SystemExit(0)
      signal.signal(signal.SIGTERM, stopped)
      signal.signal(signal.SIGINT, stopped)
      atexit.register(lambda: (touch(disconnected), touch(exited)))
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method")
          if method == "initialize":
              print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"protocolVersion":"2024-11-05", "capabilities":{}, "serverInfo":{"name":"fixture", "version":"1"}}}), flush=True)
          elif method == "tools/list":
              if mode == "suspended":
                  release_fd = os.open(release, os.O_RDONLY | os.O_NONBLOCK)
                  with open(started, "wb", buffering=0) as signal_pipe:
                      signal_pipe.write(b"1")
                  import select
                  select.select([release_fd], [], [])
                  os.read(release_fd, 1)
                  os.close(release_fd)
              print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"tools":[{"name":"owned", "description":"owned tool", "inputSchema":{"type":"object"}}]}}), flush=True)
      """#

    private static func makeFIFO(at url: URL) throws {
      guard mkfifo(url.path, 0o600) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    }

    private static func openPersistentFIFO(at url: URL) throws -> Int32 {
      let descriptor = open(url.path, O_RDWR | O_NONBLOCK)
      guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      return descriptor
    }
  }

  /// One-shot FIFO reader. Its descriptor is owned by the dispatch source and is
  /// therefore closed exactly once from the source's cancellation handler.
  private final class FIFOReadWaiter: Sendable {
    private struct State: Sendable {
      var continuation: CheckedContinuation<Void, Error>?
      var result: Result<Void, Error>?
    }

    private let descriptor: Int32
    private let state = Mutex(State())
    private let source: DispatchSourceRead

    init(descriptor: Int32) {
      self.descriptor = descriptor
      source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: .global())
      source.setEventHandler { [weak self] in
        self?.readOneByte()
      }
      source.setCancelHandler { [descriptor] in
        _ = close(descriptor)
      }
      source.resume()
    }

    func wait() async throws {
      try await withCheckedThrowingContinuation { continuation in
        let result = state.withLock { state -> Result<Void, Error>? in
          if let result = state.result {
            return result
          }
          state.continuation = continuation
          return nil
        }
        if let result {
          continuation.resume(with: result)
        }
      }
    }

    func cancel() {
      finish(.failure(CancellationError()))
    }

    private func readOneByte() {
      var byte: UInt8 = 0
      if read(descriptor, &byte, 1) == 1 {
        finish(.success(()))
      }
    }

    private func finish(_ result: Result<Void, Error>) {
      let completion = state.withLock {
        state -> (won: Bool, continuation: CheckedContinuation<Void, Error>?) in
        guard state.result == nil else { return (false, nil) }
        state.result = result
        defer { state.continuation = nil }
        return (true, state.continuation)
      }
      guard completion.won else { return }

      // Only the call that records the terminal result cancels the source.
      // Its cancel handler is the sole owner of descriptor closure.
      source.cancel()
      completion.continuation?.resume(with: result)
    }
  }

#endif
