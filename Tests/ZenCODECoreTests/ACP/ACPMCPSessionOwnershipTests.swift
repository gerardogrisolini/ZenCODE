//
//  ACPMCPSessionOwnershipTests.swift
//  ZenCODE
//
//  Proves that MCP servers provided by one ACP session are not visible to
//  non-owning sessions, and that session/close, lifecycle rollback and
//  shutdown release the session's MCP registrations.
//

#if os(macOS)
  import FeatureMCPBridgeKit
  import Foundation
  @testable import ZenCODECore
  import Testing
  import ToolCore

  /// A stdio MCP fixture that exposes exactly one tool (`owned`) and records
  /// its process exit so teardown can be observed from the test.
  private final class ACPMCPFixture: Sendable {
    let rootURL: URL
    let serverName: String
    let toolName: String
    let exitedURL: URL
    let configuration: MCPServerConfiguration

    init(serverName: String, toolName: String) throws {
      let rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("acp-mcp-ownership-\(UUID().uuidString)", isDirectory: true)
      let executableURL = rootURL.appendingPathComponent("fixture.py")
      let exitedURL = rootURL.appendingPathComponent("exited")
      let configuration = MCPServerConfiguration(
        executablePath: "/usr/bin/python3",
        arguments: [executableURL.path, exitedURL.path],
        environment: [:]
      )
      try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
      try Self.source.write(to: executableURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
      self.rootURL = rootURL
      self.serverName = serverName
      self.toolName = toolName
      self.exitedURL = exitedURL
      self.configuration = configuration
    }

    var prefixedToolName: String { "\(serverName).\(toolName)" }

    func removeFiles() {
      try? FileManager.default.removeItem(at: rootURL)
    }

    func waitForExit(timeout: TimeInterval = 5) async throws {
      let deadline = Date().addingTimeInterval(timeout)
      while Date() < deadline {
        if FileManager.default.fileExists(atPath: exitedURL.path) {
          return
        }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      Issue.record("Fixture server \(serverName) did not exit within \(timeout)s.")
    }

    private static let source = #"""
      #!/usr/bin/python3
      import atexit, json, signal, sys
      exited = sys.argv[1]
      def touch(path):
          with open(path, "w"): pass
      def stopped(signum, frame):
          touch(exited)
          raise SystemExit(0)
      signal.signal(signal.SIGTERM, stopped)
      signal.signal(signal.SIGINT, stopped)
      atexit.register(lambda: touch(exited))
      for line in sys.stdin:
          request = json.loads(line)
          method = request.get("method")
          if method == "initialize":
              print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"protocolVersion":"2024-11-05", "capabilities":{}, "serverInfo":{"name":"fixture", "version":"1"}}}), flush=True)
          elif method == "tools/list":
              print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"tools":[{"name":"owned", "description":"owned tool", "inputSchema":{"type":"object"}}]}}), flush=True)
          elif method == "tools/call":
              print(json.dumps({"jsonrpc":"2.0", "id":request["id"], "result":{"content":[{"type":"text","text":"owned-ok"}]}}), flush=True)
      """#
  }

  private func makeOwnershipBridge(
    mcpRuntime: DirectMCPToolRuntime
  ) throws -> ZenCODEACPBridge {
    let configuration = try AgentConfiguration(
      hostedModelID: "test-model",
      availableModels: [
        AgentSettingsModelManifest(
          id: "test-model",
          kind: .remoteAPI,
          modelID: "local/test-model"
        )
      ],
      runMode: .acp,
      workingDirectory: FileManager.default.temporaryDirectory
    )
    return ZenCODEACPBridge(
      configuration: configuration,
      writer: ACPWriter(),
      mcpRuntime: mcpRuntime
    )
  }

  extension ACPCompatibilityTests {
    /// The MCP server registered while creating session A must not be visible
    /// from session B on the same bridge.
    @Test
    func acpProvidedMCPServersAreIsolatedBetweenSessions() async throws {
      let fixture = try ACPMCPFixture(serverName: "alpha", toolName: "owned")
      defer { fixture.removeFiles() }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(mcpRuntime: mcpRuntime)

      // Session A owns the server.
      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-ownership-a",
        "mcpServers": [
          [
            "type": "stdio",
            "name": "alpha",
            "command": "/usr/bin/python3",
            "args": [fixture.rootURL.appendingPathComponent("fixture.py").path,
                     fixture.exitedURL.path]
          ] as [String: Any]
        ]
      ])
      let sessionA = try #require(
        await bridge.sessionConfigurationsForTesting().first?.sessionID
      )
      let sessionAView = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionA
      )
      #expect(sessionAView.map(\.name) == [fixture.prefixedToolName])

      // Session B, created without MCP servers, must not see session A's tool.
      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-ownership-b"
      ])
      let sessionB = try #require(
        await bridge.sessionConfigurationsForTesting()
          .map(\.sessionID)
          .first { $0 != sessionA }
      )
      let unscopedView = await mcpRuntime.knownDescriptors().map(\.name)
      #expect(
        !unscopedView.contains(fixture.prefixedToolName),
        "Session A's MCP tool must not appear in the unscoped runtime view.")

      let sessionBVisible = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionB
      )
      #expect(
        !sessionBVisible.map(\.name).contains(fixture.prefixedToolName),
        "Session B must not see session A's MCP tool.")
      let sessionBCanExecute = await mcpRuntime.canExecute(
        toolName: fixture.prefixedToolName,
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionB
      )
      #expect(
        !sessionBCanExecute,
        "Session B must not execute session A's MCP tool.")
      let sessionACanExecute = await mcpRuntime.canExecute(
        toolName: fixture.prefixedToolName,
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionA
      )
      #expect(
        sessionACanExecute,
        "Session A must still see and execute its own MCP tool.")

      await bridge.shutdown()
      try await fixture.waitForExit()
    }

    /// Same-named MCP servers owned by different session incarnations must not
    /// replace one another: each remains routable only through its owner and
    /// is disconnected when that owner closes.
    @Test
    func sameNamedACPProvidedMCPServersRemainIndependentAcrossSessions() async throws {
      let first = try ACPMCPFixture(serverName: "shared", toolName: "owned")
      let second = try ACPMCPFixture(serverName: "shared", toolName: "owned")
      defer {
        first.removeFiles()
        second.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(mcpRuntime: mcpRuntime)

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-same-name-a",
        "mcpServers": [[
          "type": "stdio",
          "name": first.serverName,
          "command": "/usr/bin/python3",
          "args": [first.rootURL.appendingPathComponent("fixture.py").path,
                   first.exitedURL.path]
        ] as [String: Any]]
      ])
      let sessionA = try #require(
        await bridge.sessionConfigurationsForTesting().first?.sessionID
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-same-name-b",
        "mcpServers": [[
          "type": "stdio",
          "name": second.serverName,
          "command": "/usr/bin/python3",
          "args": [second.rootURL.appendingPathComponent("fixture.py").path,
                   second.exitedURL.path]
        ] as [String: Any]]
      ])
      let sessionB = try #require(
        await bridge.sessionConfigurationsForTesting()
          .map(\.sessionID)
          .first { $0 != sessionA }
      )

      for sessionID in [sessionA, sessionB] {
        let visible = await mcpRuntime.descriptors(
          allowedToolNames: nil,
          preferredWorkspaceRootURL: nil,
          sessionID: sessionID
        ).map(\.name)
        #expect(visible == [first.prefixedToolName])
        #expect(await mcpRuntime.canExecute(
          toolName: first.prefixedToolName,
          allowedToolNames: nil,
          preferredWorkspaceRootURL: nil,
          sessionID: sessionID
        ))
        #expect(try await mcpRuntime.execute(
          toolCall: DirectAgentToolCall(
            id: UUID().uuidString,
            name: first.prefixedToolName,
            argumentsObject: [:],
            argumentsJSON: "{}"
          ),
          sessionID: sessionID
        ) == "owned-ok")
      }

      try await bridge.close(id: nil, params: ["sessionId": sessionA])
      try await first.waitForExit()
      #expect(!FileManager.default.fileExists(atPath: second.exitedURL.path))
      #expect(await mcpRuntime.canExecute(
        toolName: second.prefixedToolName,
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionB
      ))

      try await bridge.close(id: nil, params: ["sessionId": sessionB])
      try await second.waitForExit()
      await bridge.shutdown()
    }

    /// `session/close` must release the closed session's MCP registrations,
    /// without touching unrelated installations.
    @Test
    func sessionCloseReleasesTheClosedSessionsMCPServers() async throws {
      let fixture = try ACPMCPFixture(serverName: "beta", toolName: "owned")
      defer { fixture.removeFiles() }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(mcpRuntime: mcpRuntime)

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-ownership-close",
        "mcpServers": [
          [
            "type": "stdio",
            "name": "beta",
            "command": "/usr/bin/python3",
            "args": [fixture.rootURL.appendingPathComponent("fixture.py").path,
                     fixture.exitedURL.path]
          ] as [String: Any]
        ]
      ])
      let sessionID = try #require(
        await bridge.sessionConfigurationsForTesting().first?.sessionID
      )
      let ownedView = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: sessionID
      )
      #expect(ownedView.map(\.name) == [fixture.prefixedToolName])

      // An unrelated, non-ACP installation must survive the close.
      let unrelatedExecutor = RemoteMCPToolExecutor(
        configuration: MCPServerConfiguration(
          executablePath: "/usr/bin/false",
          arguments: [],
          environment: [:]
        ),
        toolNamePrefix: "unrelated."
      )
      let unrelatedName = await mcpRuntime.installBorrowedExternalExecutor(
        name: "unrelated",
        executor: unrelatedExecutor,
        tools: [
          ToolDescriptor(
            name: "shared",
            description: "unrelated",
            inputSchema: #"{"type":"object"}"#
          )
        ]
      ).map(\.name)
      #expect(unrelatedName == ["unrelated.shared"])

      try await bridge.close(id: nil, params: ["sessionId": sessionID])

      let remaining = await mcpRuntime.knownDescriptors().map(\.name)
      #expect(
        remaining == ["unrelated.shared"],
        "session/close must release only the closed session's MCP registrations.")
      try await fixture.waitForExit()
      await mcpRuntime.shutdown()
    }
    /// A fenced lifecycle operation must not leave the MCP servers it already
    /// installed behind: the release happens even when the fence lands after
    /// the first install of a multi-server registration.
    @Test
    func fencedLifecycleOperationReleasesInstalledMCPServers() async throws {
      let first = try ACPMCPFixture(serverName: "gamma", toolName: "owned")
      let second = try ACPMCPFixture(serverName: "delta", toolName: "owned")
      defer {
        first.removeFiles()
        second.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(mcpRuntime: mcpRuntime)

      // Register the operation and install one server while it is still live.
      let operation = try await bridge.registerLifecycleOperationForTesting()
      let ownership = DirectMCPToolRuntime.MCPSessionOwnership(
        sessionID: "swift-agent-fenced-rollback",
        epoch: 1
      )
      let descriptors = await bridge.registerACPProvidedMCPServers(
        from: [
          "mcpServers": [
            [
              "type": "stdio",
              "name": "gamma",
              "command": "/usr/bin/python3",
              "args": [first.rootURL.appendingPathComponent("fixture.py").path,
                       first.exitedURL.path]
            ] as [String: Any]
          ]
        ],
        ownership: ownership,
        operation: operation
      )
      #expect(descriptors.map(\.name) == ["gamma.owned"])
      let unscopedAfterInstall = await mcpRuntime.knownDescriptors().map(\.name)
      _ = unscopedAfterInstall

      // Invalidate the operation exactly like a session/close does, then
      // re-run a registration attempt for the same incarnation: it must
      // release the already-installed server instead of leaving it behind as
      // an orphan of the fenced creation.
      await bridge.invalidateBoundLifecycleOperationForTesting(
        operation,
        sessionID: ownership.sessionID,
        epoch: ownership.epoch
      )
      let fenced = await bridge.registerACPProvidedMCPServers(
        from: [
          "mcpServers": [
            [
              "type": "stdio",
              "name": "delta",
              "command": "/usr/bin/python3",
              "args": [second.rootURL.appendingPathComponent("fixture.py").path,
                       second.exitedURL.path]
            ] as [String: Any]
          ]
        ],
        ownership: ownership,
        operation: operation
      )
      #expect(fenced.isEmpty)

      #expect(
        await mcpRuntime.knownDescriptors().isEmpty,
        "A fenced operation must release the servers it already installed.")
      try await first.waitForExit()
      await bridge.shutdown()
    }
  }
#endif
