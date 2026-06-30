//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//
import Foundation
@testable import ZenCODECore
import Testing

extension ACPCompatibilityTests {
    @Test
    func newSessionSkipsUnavailableACPProvidedMCPServers() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": "/path/that/does/not/exist/mcpbridge",
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(!allowedToolNames.contains("xcode.BuildProject"))
    }

    @Test
    func newSessionSkipsInternalXcodeDiscoveryWhenACPProvidesXcodeMCPServerEvenWithoutDescriptors() async throws {
        let discoveryProbe = XcodeDiscoveryProbe()
        let mcpRuntime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                await discoveryProbe.discovery(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj")
            }
        )
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": "/path/that/does/not/exist/mcpbridge",
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode."))
        #expect(await discoveryProbe.count() == 0)
    }

    @Test
    func newSessionConsumesAllowedToolsFromACPParams() async throws {
        let backend = CapturingACPBackend()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            backendFactory: { _, _ in backend },
            mcpRuntime: Self.xcodeRuntime(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj"),
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("xcode."))
        #expect(allowedToolNames.contains("local.exec"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify tools"
        ])
        #expect(await backend.createdAllowedToolNames() == allowedToolNames)
    }

    @Test
    func newSessionDoesNotDiscoverInternalXcodeWhenACPProvidesXcodeTools() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-client-xcode-mcp-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let executableURL = supportURL.appendingPathComponent("xcode-mcp-fixture")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"XcodeRead","description":"Reads from Xcode","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}}}}]}}'
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let discoveryProbe = XcodeDiscoveryProbe()
        let mcpRuntime = DirectMCPToolRuntime(
            xcodeDiscoveryProvider: {
                await discoveryProbe.discovery(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj")
            }
        )
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["shell", "xcode"] as [String],
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": executableURL.path,
                    "args": [] as [String]
                ] as [String: Any]
            ]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode.XcodeRead"))
        #expect(await discoveryProbe.count() == 0)
    }

    @Test
    func newSessionExposesDiscoveredXcodeToolsWithoutInjectingPromptContext() async throws {
        let backend = CapturingACPBackend()
        let agent = AgentProfile(
            id: "xcode-agent",
            name: "Xcode Agent",
            tools: ["shell", "xcode"]
        )
        let mcpRuntime = Self.xcodeRuntime(workspacePath: "/tmp/acp-tools-workspace/App.xcodeproj")
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            availableAgents: [agent],
            agentName: agent.name,
            backendFactory: { _, _ in backend },
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)
        let systemPrompt = try #require(configuration.systemPrompt)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )

        #expect(allowedToolNames.contains("xcode."))
        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
        #expect(!systemPrompt.contains("Current Xcode workspace context:"))
        #expect(!systemPrompt.contains("Available Xcode tools in this session:"))
        #expect(!systemPrompt.contains("`xcode.BuildProject`"))
        try await bridge.prompt(id: nil, params: [
            "sessionId": configuration.sessionID,
            "prompt": "verify Xcode tools"
        ])
        #expect(await backend.createdSystemPrompt()?.contains("`xcode.BuildProject`") != true)
    }

    @Test
    func newSessionIgnoresNonStandardSystemPromptParameter() async throws {
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-system-prompt-workspace",
            "systemPrompt": "CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let systemPrompt = try #require(configuration.systemPrompt)

        #expect(!systemPrompt.contains("CLIENT-SYSTEM-PROMPT-SHOULD-NOT-BE-INJECTED"))
    }

    @Test
    func newSessionUsesHostedDefaultThinkingWhenThinkingIsNotProvided() async throws {
        let bridge = try makeBridge(
            models: [
                Self.thinkingModel(defaultThinkingSelection: .high)
            ]
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionUsesAgentThinkingOverHostedDefault() async throws {
        let model = Self.thinkingModel(defaultThinkingSelection: .medium)
        let agent = AgentProfile(
            id: "thinking-agent",
            name: "Thinking Agent",
            tools: [],
            modelID: model.id,
            thinkingSelection: .high
        )
        let bridge = try makeBridge(
            models: [model],
            availableAgents: [agent],
            agentName: agent.name
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-thinking-workspace"
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)

        #expect(configuration.modelID == model.id)
        #expect(configuration.thinkingSelection == .high)
    }

    @Test
    func newSessionKeepsXcodeSelectionWhenXcodeIsClosed() async throws {
        let mcpRuntime = DirectMCPToolRuntime()
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { false }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode."))
        #expect(configuration.systemPrompt?.contains("Available Xcode tools in this session:") != true)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )
        #expect(descriptors.isEmpty)
    }

    @Test
    func newSessionKeepsXcodeSelectionWhenXcodeWorkspaceDiffers() async throws {
        let mcpRuntime = Self.xcodeRuntime(workspacePath: "/tmp/other-workspace/App.xcodeproj")
        let bridge = try makeBridge(
            models: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            mcpRuntime: mcpRuntime,
            xcodeIsRunning: { true }
        )

        try await bridge.newSession(id: nil, params: [
            "cwd": "/tmp/acp-tools-workspace",
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        let configuration = try #require(await bridge.sessionConfigurationsForTesting().first)
        let allowedToolNames = try #require(configuration.allowedToolNames)

        #expect(allowedToolNames.contains("local.exec"))
        #expect(allowedToolNames.contains("xcode."))
        #expect(configuration.systemPrompt?.contains("Available Xcode tools in this session:") != true)
        let descriptors = await mcpRuntime.knownDescriptors(
            allowedToolNames: ["xcode."],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/acp-tools-workspace")
        )
        #expect(descriptors.isEmpty)
    }

    @Test
    func parsedACPXcodeSelectionExposesBorrowedXcodeDescriptors() async throws {
        let allowedTools = try #require(ZenCODEACPBridge.allowedToolNames(from: [
            "allowed_tools": ["xcode"] as [String]
        ]))
        let mcpRuntime = DirectMCPToolRuntime()
        let xcodeExecutor = XcodeToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            )
        )
        await mcpRuntime.installBorrowedXcodeExecutor(
            xcodeExecutor,
            tools: [
                ToolDescriptor(
                    name: "BuildProject",
                    description: "Builds an Xcode project",
                    inputSchema: "{}"
                )
            ]
        )

        let descriptors = await mcpRuntime.descriptors(
            allowedToolNames: allowedTools
        )

        #expect(descriptors.map(\.name) == ["xcode.BuildProject"])
    }

    @Test
    func installingSameACPProvidedXcodeMCPServerReusesActiveConnection() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-xcode-mcp-reuse-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let launchesURL = supportURL.appendingPathComponent("launches.txt")
        let executableURL = supportURL.appendingPathComponent("xcode-mcp-fixture")
        try #"""
        #!/bin/sh
        printf 'launch\n' >> "\#(launchesURL.path)"
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -E -n 's/.*"id"[[:space:]]*:[[:space:]]*([^,}]*).*/\1/p')
          case "$line" in
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"XcodeRead","description":"Reads from Xcode","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}}}}]}}'
              ;;
          esac
        done
        """#.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = DirectMCPToolRuntime()
        let configuration = MCPServerConfiguration(
            executablePath: executableURL.path,
            arguments: [],
            environment: ["MCP_XCODE_SESSION_ID": "session-1"]
        )
        let firstDescriptors = try await runtime.installExternalMCPServer(
            name: "Xcode",
            configuration: configuration
        )
        let secondDescriptors = try await runtime.installExternalMCPServer(
            name: "Xcode",
            configuration: configuration
        )
        let launches = try String(contentsOf: launchesURL, encoding: .utf8)
            .split(separator: "\n")

        #expect(firstDescriptors.map(\.name) == ["xcode.XcodeRead"])
        #expect(secondDescriptors.map(\.name) == ["xcode.XcodeRead"])
        #expect(launches.count == 1)
    }

    @Test
    func acpProvidedXcodeMCPServerRegistersThroughCentralRuntime() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-xcode-mcp-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(
            at: supportURL,
            withIntermediateDirectories: true
        )
        let requestURL = supportURL.appendingPathComponent("request.jsonl")
        let executableURL = supportURL.appendingPathComponent("xcode-mcp-fixture")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s\n' "$line" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\\([^,}]*\\).*/\\1/p')
          case "$line" in
            *initialize*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
            *tools*list*)
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"tools":[{"name":"XcodeRead","description":"Reads from Xcode","inputSchema":{"type":"object","properties":{"filePath":{"type":"string"}}}}]}}'
              ;;
            *tools*call*)
              printf '%s\n' "$line" > "\(requestURL.path)"
              printf '%s\n' '{"jsonrpc":"2.0","id":'"$id"',"result":{"content":[{"type":"text","text":"ok"}]}}'
              exit 0
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = DirectMCPToolRuntime()
        let descriptors = try await runtime.installExternalMCPServer(
            name: "Xcode",
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            )
        )
        let output = try await runtime.execute(
            toolCall: DirectAgentToolCall(
                id: "call-1",
                name: "xcode.read",
                argumentsObject: ["path": "Sources/App/File.swift"],
                argumentsJSON: #"{"path":"Sources/App/File.swift"}"#
            )
        )
        let capturedRequestData = try Data(contentsOf: requestURL)
        let capturedRequest = try #require(
            JSONSerialization.jsonObject(with: capturedRequestData) as? [String: Any]
        )
        let capturedParams = try #require(capturedRequest["params"] as? [String: Any])
        let capturedArguments = try #require(capturedParams["arguments"] as? [String: Any])

        #expect(descriptors.map(\.name) == ["xcode.XcodeRead"])
        #expect(output == "ok")
        #expect(capturedParams["name"] as? String == "XcodeRead")
        #expect(capturedArguments["filePath"] as? String == "Sources/App/File.swift")
    }
}
