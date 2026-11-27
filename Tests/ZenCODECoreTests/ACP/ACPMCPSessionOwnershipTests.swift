//
//  ACPMCPSessionOwnershipTests.swift
//  ZenCODE
//
//  Proves that MCP servers provided by one ACP session are not visible to
//  non-owning sessions, that session/close, lifecycle rollback and
//  shutdown release the session's MCP registrations, and that a server a
//  loaded feature of the same name replaces is never started, whatever the
//  session's tool grant selects: the session is granted the feature's tools
//  in its place.
//

#if os(macOS)
  import FeatureMCPBridgeKit
  import Foundation
  @testable import ZenCODECore
  @testable import ZenCODERuntime
  import Testing
  import ToolCore

  /// A stdio MCP fixture that exposes exactly one tool (`owned`) and records
  /// its process exit so teardown can be observed from the test.
  private final class ACPMCPFixture: Sendable {
    let rootURL: URL
    let serverName: String
    let toolName: String
    let exitedURL: URL
    /// Written when the fixture process starts: its absence proves that the
    /// server was never launched.
    let startedURL: URL
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
      self.startedURL = rootURL.appendingPathComponent("started")
      self.configuration = configuration
    }

    var prefixedToolName: String { "\(serverName).\(toolName)" }

    /// The `mcpServers` entry of a session request that starts this fixture.
    var definition: [String: Any] {
      [
        "type": "stdio",
        "name": serverName,
        "command": "/usr/bin/python3",
        "args": [rootURL.appendingPathComponent("fixture.py").path, exitedURL.path]
      ]
    }

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
      import atexit, json, os, signal, sys
      exited = sys.argv[1]
      def touch(path):
          with open(path, "w"): pass
      touch(os.path.join(os.path.dirname(exited), "started"))
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
    mcpRuntime: DirectMCPToolRuntime,
    swiftFeatureRuntime: SwiftFeatureRuntime = SwiftFeatureRuntime()
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
      mcpRuntime: mcpRuntime,
      swiftFeatureRuntime: swiftFeatureRuntime
    )
  }

  /// A bridge whose launch selected no agent (`AgentConfiguration` built from
  /// the command line alone), so a session that brings no `allowedTools` has no
  /// tool grant of its own (`nil`): the case where the servers of a request are
  /// what restricts it.
  private func makeAgentlessOwnershipBridge(
    mcpRuntime: DirectMCPToolRuntime,
    swiftFeatureRuntime: SwiftFeatureRuntime
  ) throws -> ZenCODEACPBridge {
    ZenCODEACPBridge(
      configuration: try AgentConfiguration.withoutPersistedConfiguration(
        arguments: ["--acp", "--model", "test-model"]
      ),
      writer: ACPWriter(),
      mcpRuntime: mcpRuntime,
      swiftFeatureRuntime: swiftFeatureRuntime
    )
  }

  /// Runs `body` with the support directory scoped to a UUID temporary one,
  /// removed afterwards, so nothing reads or writes the real `~/.zencode`.
  private func withTemporarySupportDirectory(
    _ body: () async throws -> Void
  ) async throws {
    let support = FileManager.default.temporaryDirectory
      .appendingPathComponent("acp-mcp-feature-support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: support) }
    try await AppStorageDirectory.withSupportDirectoryURL(support) {
      try await body()
    }
  }

  /// A runtime whose only feature, `demo-tools`, owns the tool `demo.run` and
  /// never starts a process to list it.
  private func makeDemoFeatureRuntime() -> SwiftFeatureRuntime {
    SwiftFeatureRuntime(features: [
      SwiftFeatureBundle(
        id: "demo-tools",
        executableURL: URL(fileURLWithPath: "/usr/bin/false"),
        tools: [
          ToolDescriptor(
            name: "demo.run",
            description: "demo tool",
            inputSchema: #"{"type":"object"}"#
          )
        ]
      )
    ])
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

    /// A client-provided MCP server named like a feature the session's own
    /// tool grant selects is the same integration offered twice: it is never
    /// started, so only the feature connects (and asks for its consent). The
    /// other servers of the same request are installed as usual.
    @Test
    func clientMCPServerNamedLikeAGrantedFeatureIsNotStarted() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: makeDemoFeatureRuntime()
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-feature-replaced",
        "allowedTools": ["demo.run"],
        "mcpServers": [replaced.definition, kept.definition]
      ])
      let configuration = try #require(
        await bridge.sessionConfigurationsForTesting().first
      )

      let visible = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: configuration.sessionID
      ).map(\.name)
      #expect(visible == [kept.prefixedToolName])
      #expect(FileManager.default.fileExists(atPath: kept.startedURL.path))
      #expect(
        !FileManager.default.fileExists(atPath: replaced.startedURL.path),
        "The server the session's feature replaces must never be launched.")

      let allowedToolNames = try #require(configuration.allowedToolNames)
      #expect(allowedToolNames.contains("demo.run"))
      #expect(allowedToolNames.contains(kept.prefixedToolName))
      #expect(!allowedToolNames.contains(replaced.prefixedToolName))

      await bridge.shutdown()
      try await kept.waitForExit()
    }

    /// The restore of a session that is not live installs its MCP servers
    /// through the same path: a server its feature replaces is not started.
    @Test
    func restoredSessionDoesNotStartAClientMCPServerItsFeatureReplaces() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: makeDemoFeatureRuntime()
      )

      try await bridge.resumeSession(id: nil, params: [
        "sessionId": "client-feature-replaced",
        "cwd": "/tmp/acp-mcp-feature-replaced-resume",
        "allowedTools": ["demo.run"],
        "mcpServers": [replaced.definition, kept.definition]
      ])

      let visible = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: "client-feature-replaced"
      ).map(\.name)
      #expect(visible == [kept.prefixedToolName])
      #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))

      await bridge.shutdown()
      try await kept.waitForExit()
    }

    /// A loaded feature replaces the client's server of its name whatever the
    /// session's own tool grant selects: with `allowedTools: ["local.read"]`
    /// the feature is outside the grant, yet the server is never started or
    /// visible, and the grant gains exactly the names a profile selecting
    /// `feature:demo-tools` is given (never the server's tools).
    @Test
    func clientMCPServerNamedLikeALoadedFeatureOutsideTheGrantIsNotStarted() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let featureRuntime = makeDemoFeatureRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: featureRuntime
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-feature-outside-grant-\(UUID().uuidString)",
        "allowedTools": ["local.read"],
        "mcpServers": [replaced.definition, kept.definition]
      ])
      let configuration = try #require(
        await bridge.sessionConfigurationsForTesting().first
      )

      let visible = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: configuration.sessionID
      ).map(\.name)
      #expect(visible == [kept.prefixedToolName])
      #expect(FileManager.default.fileExists(atPath: kept.startedURL.path))
      #expect(
        !FileManager.default.fileExists(atPath: replaced.startedURL.path),
        "A loaded feature replaces the client's server even when the grant does not select it.")

      let allowedToolNames = try #require(configuration.allowedToolNames)
      #expect(allowedToolNames.contains("local.read"))
      #expect(allowedToolNames.contains(kept.prefixedToolName))
      #expect(!allowedToolNames.contains(replaced.prefixedToolName))
      #expect(DirectToolExecutor.isAllowed("demo.run", allowedToolNames: allowedToolNames))
      #expect(
        await featureRuntime.featureToolIsAllowed(
          toolName: "demo.run",
          allowedToolNames: allowedToolNames
        ))
      #expect(!DirectToolExecutor.isAllowed("local.exec", allowedToolNames: allowedToolNames))

      // An agent mention recomposes the grant from the session's own one: the
      // feature's names must survive it, as the servers' tools do.
      let base = try #require(await bridge.baseAllowedToolNamesForTesting())
      #expect(base.contains("demo.run"))
      let mentioned = try #require(
        await bridge.configurationRoutedForTesting(
          to: AgentProfile(id: "mentioned", name: "Mentioned", role: .developer, tools: [])
        )?.allowedToolNames
      )
      #expect(mentioned.contains("demo.run"))
      #expect(mentioned.contains(kept.prefixedToolName))
      #expect(!mentioned.contains(replaced.prefixedToolName))

      await bridge.shutdown()
      try await kept.waitForExit()
    }

    /// The server name is compared as the runtime normalizes it, not
    /// byte for byte: `Demo Tools` is the id of the `demo-tools` feature.
    @Test
    func clientMCPServerNameIsComparedToFeatureIDsNormalized() async throws {
      let replaced = try ACPMCPFixture(serverName: "Demo Tools", toolName: "owned")
      defer { replaced.removeFiles() }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: makeDemoFeatureRuntime()
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-feature-normalized-\(UUID().uuidString)",
        "allowedTools": ["local.read"],
        "mcpServers": [replaced.definition]
      ])
      let configuration = try #require(
        await bridge.sessionConfigurationsForTesting().first
      )

      #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))
      let allowedToolNames = try #require(configuration.allowedToolNames)
      #expect(allowedToolNames.contains("demo.run"))

      await bridge.shutdown()
    }

    /// A server whose name matches no loaded feature has no other source for
    /// its tools: it is installed, as any other, and nothing is added for the
    /// feature the runtime does load.
    @Test
    func clientMCPServerWithNoLoadedFeatureOfItsNameIsInstalled() async throws {
      let fixture = try ACPMCPFixture(serverName: "unrelated-tools", toolName: "owned")
      defer { fixture.removeFiles() }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: makeDemoFeatureRuntime()
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-feature-no-match-\(UUID().uuidString)",
        "allowedTools": ["local.read"],
        "mcpServers": [fixture.definition]
      ])
      let configuration = try #require(
        await bridge.sessionConfigurationsForTesting().first
      )

      let visible = await mcpRuntime.descriptors(
        allowedToolNames: nil,
        preferredWorkspaceRootURL: nil,
        sessionID: configuration.sessionID
      ).map(\.name)
      #expect(visible == [fixture.prefixedToolName])
      #expect(FileManager.default.fileExists(atPath: fixture.startedURL.path))
      let allowedToolNames = try #require(configuration.allowedToolNames)
      #expect(allowedToolNames.contains(fixture.prefixedToolName))
      #expect(!allowedToolNames.contains("demo.run"))

      await bridge.shutdown()
      try await fixture.waitForExit()
    }

    /// A feature that is not loaded (here: the runtime has none) replaces
    /// nothing: the client's server of the same name is installed.
    @Test
    func clientMCPServerNamedLikeAnUnloadedFeatureIsInstalled() async throws {
      let fixture = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      defer { fixture.removeFiles() }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: SwiftFeatureRuntime(features: [])
      )

      try await bridge.newSession(id: nil, params: [
        "cwd": "/tmp/acp-mcp-feature-unloaded-\(UUID().uuidString)",
        "allowedTools": ["local.read"],
        "mcpServers": [fixture.definition]
      ])
      let configuration = try #require(
        await bridge.sessionConfigurationsForTesting().first
      )

      #expect(FileManager.default.fileExists(atPath: fixture.startedURL.path))
      let allowedToolNames = try #require(configuration.allowedToolNames)
      #expect(allowedToolNames.contains(fixture.prefixedToolName))
      #expect(!allowedToolNames.contains("demo.run"))

      await bridge.shutdown()
      try await fixture.waitForExit()
    }

    /// The restore of a session that is not live follows the same rule: the
    /// loaded feature outside the grant replaces the server, and the grant of
    /// the restored session gains the feature's names.
    @Test
    func restoredSessionDoesNotStartAClientMCPServerOfALoadedFeatureOutsideTheGrant() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      try await withTemporarySupportDirectory {
        let mcpRuntime = DirectMCPToolRuntime()
        let bridge = try makeOwnershipBridge(
          mcpRuntime: mcpRuntime,
          swiftFeatureRuntime: makeDemoFeatureRuntime()
        )
        let sessionID = "client-feature-outside-grant-\(UUID().uuidString)"

        try await bridge.resumeSession(id: nil, params: [
          "sessionId": sessionID,
          "cwd": "/tmp/acp-mcp-feature-outside-grant-resume-\(UUID().uuidString)",
          "allowedTools": ["local.read"],
          "mcpServers": [replaced.definition, kept.definition]
        ])

        let visible = await mcpRuntime.descriptors(
          allowedToolNames: nil,
          preferredWorkspaceRootURL: nil,
          sessionID: sessionID
        ).map(\.name)
        #expect(visible == [kept.prefixedToolName])
        #expect(FileManager.default.fileExists(atPath: kept.startedURL.path))
        #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))
        let configuration = try #require(
          await bridge.sessionConfigurationsForTesting().first
        )
        let allowedToolNames = try #require(configuration.allowedToolNames)
        #expect(allowedToolNames.contains("local.read"))
        #expect(allowedToolNames.contains("demo.run"))
        #expect(allowedToolNames.contains(kept.prefixedToolName))
        #expect(!allowedToolNames.contains(replaced.prefixedToolName))
        let base = try #require(await bridge.baseAllowedToolNamesForTesting())
        #expect(base.contains("demo.run"))

        await bridge.shutdown()
        try await kept.waitForExit()
      }
    }

    /// The restore of a session with no grant of its own follows the same
    /// semantic: the replacing feature's names and the other servers' tools
    /// only, plus the prompt-skill tools.
    @Test
    func restoredSessionWithoutAGrantIsGrantedTheReplacingFeatureAndTheOtherServersOnly() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      try await withTemporarySupportDirectory {
        let bridge = try makeAgentlessOwnershipBridge(
          mcpRuntime: DirectMCPToolRuntime(),
          swiftFeatureRuntime: makeDemoFeatureRuntime()
        )

        try await bridge.resumeSession(id: nil, params: [
          "sessionId": "client-feature-no-grant-\(UUID().uuidString)",
          "cwd": "/tmp/acp-mcp-feature-no-grant-resume-\(UUID().uuidString)",
          "mcpServers": [replaced.definition, kept.definition]
        ])
        let configuration = try #require(
          await bridge.sessionConfigurationsForTesting().first
        )

        #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))
        #expect(
          configuration.allowedToolNames
            == Set(["demo.run", kept.prefixedToolName]).union(PromptSkillToolProvider.toolNames))
        #expect(await bridge.baseAllowedToolNamesForTesting() == configuration.allowedToolNames)

        await bridge.shutdown()
        try await kept.waitForExit()
      }
    }

    /// A session with no grant of its own (no `allowedTools`, no agent) that
    /// installs a server is granted the tools of its servers only, plus the
    /// prompt-skill tools. With a replacing feature the feature's names stand
    /// in for the replaced server's: the grant is the feature's names and the
    /// tools of the other installed servers, never `nil` (everything), never
    /// the replaced server's tools.
    @Test
    func sessionWithoutAGrantIsGrantedTheReplacingFeatureAndTheOtherServersOnly() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      try await withTemporarySupportDirectory {
        let bridge = try makeAgentlessOwnershipBridge(
          mcpRuntime: DirectMCPToolRuntime(),
          swiftFeatureRuntime: makeDemoFeatureRuntime()
        )

        try await bridge.newSession(id: nil, params: [
          "cwd": "/tmp/acp-mcp-feature-no-grant-\(UUID().uuidString)",
          "mcpServers": [replaced.definition, kept.definition]
        ])
        let configuration = try #require(
          await bridge.sessionConfigurationsForTesting().first
        )

        #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))
        #expect(
          configuration.allowedToolNames
            == Set(["demo.run", kept.prefixedToolName]).union(PromptSkillToolProvider.toolNames))
        #expect(await bridge.baseAllowedToolNamesForTesting() == configuration.allowedToolNames)

        await bridge.shutdown()
        try await kept.waitForExit()
      }
    }

    /// With the replacing feature as the only server of a session without a
    /// grant, the grant is the feature's names plus the prompt-skill tools:
    /// the same "restricted to what the session provided" semantic a server
    /// gives, not "no restriction".
    @Test
    func sessionWithoutAGrantWhoseOnlyServerIsReplacedIsGrantedTheFeatureOnly() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      defer { replaced.removeFiles() }
      try await withTemporarySupportDirectory {
        let bridge = try makeAgentlessOwnershipBridge(
          mcpRuntime: DirectMCPToolRuntime(),
          swiftFeatureRuntime: makeDemoFeatureRuntime()
        )

        try await bridge.newSession(id: nil, params: [
          "cwd": "/tmp/acp-mcp-feature-no-grant-only-\(UUID().uuidString)",
          "mcpServers": [replaced.definition]
        ])
        let configuration = try #require(
          await bridge.sessionConfigurationsForTesting().first
        )

        #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))
        #expect(
          configuration.allowedToolNames
            == Set(["demo.run"]).union(PromptSkillToolProvider.toolNames))

        await bridge.shutdown()
      }
    }

    /// Without a replacing feature the semantic of a session with no grant is
    /// the one it always had: the tools of the installed servers (plus the
    /// prompt-skill tools) and nothing of the loaded features.
    @Test
    func sessionWithoutAGrantAndNoReplacedServerIsGrantedItsServersOnly() async throws {
      let fixture = try ACPMCPFixture(serverName: "unrelated-tools", toolName: "owned")
      defer { fixture.removeFiles() }
      try await withTemporarySupportDirectory {
        let bridge = try makeAgentlessOwnershipBridge(
          mcpRuntime: DirectMCPToolRuntime(),
          swiftFeatureRuntime: makeDemoFeatureRuntime()
        )

        try await bridge.newSession(id: nil, params: [
          "cwd": "/tmp/acp-mcp-feature-no-grant-unrelated-\(UUID().uuidString)",
          "mcpServers": [fixture.definition]
        ])
        let configuration = try #require(
          await bridge.sessionConfigurationsForTesting().first
        )

        #expect(FileManager.default.fileExists(atPath: fixture.startedURL.path))
        #expect(
          configuration.allowedToolNames
            == Set([fixture.prefixedToolName]).union(PromptSkillToolProvider.toolNames))

        await bridge.shutdown()
        try await fixture.waitForExit()
      }
    }

    /// `registerACPProvidedMCPServers` keeps its public signature: the
    /// `requestedAllowedToolNames` it still accepts no longer decides which
    /// server a feature replaces.
    @Test
    func registerACPProvidedMCPServersKeepsItsSignatureAndReplacesRegardlessOfTheGrant() async throws {
      let replaced = try ACPMCPFixture(serverName: "demo-tools", toolName: "owned")
      let kept = try ACPMCPFixture(serverName: "other", toolName: "owned")
      defer {
        replaced.removeFiles()
        kept.removeFiles()
      }
      let mcpRuntime = DirectMCPToolRuntime()
      let bridge = try makeOwnershipBridge(
        mcpRuntime: mcpRuntime,
        swiftFeatureRuntime: makeDemoFeatureRuntime()
      )

      let descriptors = await bridge.registerACPProvidedMCPServers(
        from: ["mcpServers": [replaced.definition, kept.definition]],
        requestedAllowedToolNames: ["local.read"],
        ownership: DirectMCPToolRuntime.MCPSessionOwnership(
          sessionID: "register-wrapper",
          epoch: 1
        )
      )

      #expect(descriptors.map(\.name) == [kept.prefixedToolName])
      #expect(!FileManager.default.fileExists(atPath: replaced.startedURL.path))

      await bridge.shutdown()
      try await kept.waitForExit()
    }
  }

  extension ZenCODEACPBridge {
    /// The base grant (before an agent narrows it) of the only live session.
    fileprivate func baseAllowedToolNamesForTesting() -> Set<String>? {
      sessions.values.first?.baseAllowedToolNames
    }

    /// The configuration the only live session gets once an `@Agent` mention
    /// routes it to `agent`.
    fileprivate func configurationRoutedForTesting(
      to agent: AgentProfile
    ) -> AgentCoreSessionConfiguration? {
      sessions.values.first.map { acpSessionConfiguration(applying: agent, to: $0) }
    }
  }
#endif
