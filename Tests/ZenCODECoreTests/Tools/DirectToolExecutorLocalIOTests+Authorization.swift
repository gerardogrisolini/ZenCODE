//
//  DirectToolExecutorLocalIOTests+Authorization.swift
//  ZenCODE
//
//  Authorization tests of the direct tool executor: compatibility aliases,
//  external prefixes and the priority of registered feature, MCP and provider
//  tools.
//

import Foundation
@testable import ZenCODECore
import FeatureKit
import FeatureMCPBridgeKit
import LocalToolsSupport
import Testing
import ToolCore

@Suite
struct DirectToolExecutorAuthorizationTests {
    @Test
    func readOnlyProfilesRejectMutableCoreCompatibilityAliases() async {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let executor = makeExecutor()
        let aliases = [
            "agent.spawn",
            "agent_spawn",
            "subagent.create",
            "todo.update",
            "todo_update",
            "tasks_update",
            "AGENT.SPAWN"
        ]

        for alias in aliases {
            let allowedToolNames = profile.resolvedAllowedToolNames([alias])
            let result = await executor.execute(
                sessionID: "read-only-alias",
                toolCall: toolCall(named: alias),
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                allowedToolNames: allowedToolNames
            )

            #expect(result.status == .permissionDenied, "Expected \(alias) to be denied.")
            #expect(result.isPermissionDenied)
        }

        await executor.shutdown()
    }

    @Test
    func compatibilityAliasUsesCanonicalGrantWhenItIsAuthorized() async {
        let executor = makeExecutor()
        let result = await executor.execute(
            sessionID: "canonical-alias",
            toolCall: toolCall(
                named: "todo_update",
                arguments: ["content": "Keep this todo."]
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["todo.write"]
        )

        #expect(result.status == .completed)
        #expect(result.output.contains("Keep this todo."))
        await executor.shutdown()
    }

    @Test
    func externalPrefixCannotFallBackToAMutableCoreCompatibilityTool() async {
        let profile = AgentProfile(
            id: "read-only",
            name: "Read Only",
            readOnly: true,
            role: .developer
        )
        let executor = makeExecutor()
        let rawToolName = "external.agent.create"

        #expect(
            SubAgentToolRequestCompatibility.canonicalToolName(for: rawToolName)
                == "agent.create"
        )
        let result = await executor.execute(
            sessionID: "external-prefix-fallback",
            toolCall: toolCall(named: rawToolName),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: profile.resolvedAllowedToolNames(["external."])
        )

        #expect(result.status == .permissionDenied)
        #expect(result.isPermissionDenied)
        await executor.shutdown()
    }

    @Test
    func registeredExternalToolKeepsPriorityOverCompatibilityFallback() async {
        let executor = makeExecutor()
        let rawToolName = "external.agent.create"
        await executor.updateToolProviders([
            AgentToolProvider(
                tools: [
                    ToolDescriptor(
                        name: rawToolName,
                        description: "External provider fixture.",
                        inputSchema: #"{"type":"object","properties":{}}"#
                    )
                ],
                executor: { _ in "external provider handled the raw tool" }
            )
        ])

        let result = await executor.execute(
            sessionID: nil,
            toolCall: toolCall(named: rawToolName),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["external."]
        )

        #expect(result.status == .completed)
        #expect(result.output == "external provider handled the raw tool")
        await executor.shutdown()
    }

    @Test
    func perSessionProviderRegistriesAreEvictedOnCloseAndShutdown() async {
        let executor = makeExecutor()
        let provider = AgentToolProvider(
            tools: [
                ToolDescriptor(
                    name: "session.fixture",
                    description: "Session provider fixture.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ],
            executor: { _ in "ok" }
        )

        await executor.updateToolProviders([provider], sessionID: "one")
        await executor.updateToolProviders([provider], sessionID: "two")
        #expect(await executor.hasToolProviderRegistry(sessionID: "one"))
        #expect(await executor.hasToolProviderRegistry(sessionID: "two"))

        await executor.removeToolProviders(sessionID: "one")
        #expect(!(await executor.hasToolProviderRegistry(sessionID: "one")))
        #expect(await executor.hasToolProviderRegistry(sessionID: "two"))

        await executor.shutdown()
        #expect(!(await executor.hasToolProviderRegistry(sessionID: "two")))
    }

    @Test
    func registeredFeatureToolKeepsPriorityOverCompatibilityFallback() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-core-alias-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"external feature handled the raw tool"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let rawToolName = "external.agent.create"
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(
                features: [
                    SwiftFeatureBundle(
                        id: "external-feature-fixture",
                        executableURL: executableURL,
                        tools: [
                            ToolDescriptor(
                                name: rawToolName,
                                description: "External feature fixture.",
                                inputSchema: #"{"type":"object","properties":{}}"#
                            )
                        ]
                    )
                ]
            ),
            subAgentContextualBackendFactory: { _ in TestAgentRuntimeBackend() }
        )

        let result = await executor.execute(
            sessionID: nil,
            toolCall: toolCall(named: rawToolName),
            workingDirectory: rootURL,
            allowedToolNames: ["external."]
        )

        #expect(result.status == .completed)
        #expect(result.output == "external feature handled the raw tool")
        await executor.shutdown()
    }

    @Test
    func registeredMCPToolKeepsPriorityOverCompatibilityFallback() async {
        let rawToolName = "external.agent.create"
        let mcpRuntime = DirectMCPToolRuntime()
        let remoteExecutor = RemoteMCPToolExecutor(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/false",
                arguments: [],
                environment: [:]
            ),
            toolNamePrefix: "external."
        )
        _ = await mcpRuntime.installBorrowedExternalExecutor(
            name: "external",
            executor: remoteExecutor,
            tools: [
                ToolDescriptor(
                    name: "agent.create",
                    description: "External MCP fixture.",
                    inputSchema: #"{"type":"object","properties":{}}"#
                )
            ]
        )
        let executor = DirectToolExecutor(
            mcpRuntime: mcpRuntime,
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in TestAgentRuntimeBackend() }
        )

        let result = await executor.execute(
            sessionID: nil,
            toolCall: toolCall(named: rawToolName),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["external."]
        )

        // The borrowed executor intentionally fails its transport connection.
        // Reaching that failure instead of permissionDenied proves MCP dispatch
        // retains priority over the compatibility fallback.
        #expect(result.status == .failed)
        #expect(!result.isPermissionDenied)
        await executor.shutdown()
        await remoteExecutor.disconnect()
    }

    private func makeExecutor() -> DirectToolExecutor {
        DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in TestAgentRuntimeBackend() }
        )
    }

    private func toolCall(
        named name: String,
        arguments: [String: Any] = [:]
    ) -> DirectAgentToolCall {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: UUID().uuidString,
            name: name,
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }
}
