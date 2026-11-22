//
//  DirectToolExecutorRoutingCharacterizationTests.swift
//  ZenCODE
//
//  End-to-end routing table for `DirectToolExecutor.execute` and
//  `executeThrowingResult`: for each combination of tool name, allowlist,
//  feature ownership, provider and MCP registration, borrowed sub-agent
//  executor, and operator decision, it pins which implementation handles the
//  call (observable from its output), or which error with which text, and
//  which authorization requests the gates raise.
//

import FeatureMCPBridgeKit
import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite
struct DirectToolExecutorRoutingCharacterizationTests {
    enum Authorization: Sendable {
        case approve
        case deny
    }

    enum Expected: Sendable {
        case exact(String)
        case contains(String)
    }

    struct Fixture: Sendable {
        var featureTools: [String] = []
        var featureAliases: [String] = []
        var providerTools: [String] = []
        /// Raw MCP tool names installed under the `remote.` prefix.
        var mcpTools: [String] = []
        var borrowedSubAgentExecutor = false
        var authorization: Authorization = .approve
        var sessionID: String? = "routing-session"
    }

    struct RoutingCase: Sendable, CustomTestStringConvertible {
        let label: String
        let toolName: String
        let argumentsJSON: String
        let allowedToolNames: Set<String>?
        let fixture: Fixture
        let expected: Expected
        let status: DirectAgentToolResult.Status
        /// Tool names of the authorization requests raised, in order.
        let authorizationRequests: [String]
        let featureInvoked: Bool

        var testDescription: String { label }
    }

    static func row(
        _ label: String,
        _ toolName: String,
        _ argumentsJSON: String = "{}",
        allowed: Set<String>?,
        _ fixture: Fixture = Fixture(),
        expect expected: Expected,
        status: DirectAgentToolResult.Status = .completed,
        requests: [String] = [],
        featureInvoked: Bool = false
    ) -> RoutingCase {
        RoutingCase(
            label: label,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            allowedToolNames: allowed,
            fixture: fixture,
            expected: expected,
            status: status,
            authorizationRequests: requests,
            featureInvoked: featureInvoked
        )
    }

    static func notEnabled(_ toolName: String) -> Expected {
        .exact("Tool error: The tool '\(toolName)' is not enabled for this agent session.")
    }

    static func unknown(_ toolName: String) -> Expected {
        .exact("Tool error: Unknown tool: \(toolName)")
    }

    /// The borrowed executor's transport (`/usr/bin/false`) fails on purpose:
    /// reaching an MCP transport error proves the MCP route was taken.
    static let mcpFailure = Expected.contains("MCP")

    @Test(arguments: routingCases)
    func executeRoutingTable(_ row: RoutingCase) async throws {
        let environment = try RoutingEnvironment(fixture: row.fixture)
        defer { environment.remove() }
        let result = try await environment.run { executor in
            await executor.execute(
                sessionID: row.fixture.sessionID,
                toolCall: Self.toolCall(row.toolName, row.argumentsJSON),
                workingDirectory: environment.workspace.workspaceURL,
                allowedToolNames: row.allowedToolNames
            )
        }

        switch row.expected {
        case let .exact(output):
            #expect(result.output == output)
        case let .contains(fragment):
            #expect(result.output.contains(fragment), "\(result.output)")
        }
        #expect(result.status == row.status, "\(result.output)")
        #expect(await environment.authorizations.toolNames == row.authorizationRequests)
        #expect(environment.featureWasInvoked == row.featureInvoked)
    }

    struct ThrowingCase: Sendable, CustomTestStringConvertible {
        let label: String
        let toolName: String
        let allowedToolNames: Set<String>?
        let fixture: Fixture
        /// `localizedDescription` of the thrown error.
        let error: String
        let isToolNotAllowed: Bool

        var testDescription: String { label }
    }

    /// `executeThrowingResult` has no outer allowlist guard: a tool that is
    /// neither directly nor feature allowed reaches the dispatch chain.
    static let throwingCases: [ThrowingCase] = [
        ThrowingCase(
            label: "core tool not allowed",
            toolName: "local.read",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(),
            error: "Unknown tool: local.read",
            isToolNotAllowed: false
        ),
        ThrowingCase(
            label: "feature tool not allowed",
            toolName: "fx.tool",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(featureTools: ["fx.tool"]),
            error: "Unknown tool: fx.tool",
            isToolNotAllowed: false
        ),
        ThrowingCase(
            label: "provider tool not allowed",
            toolName: "ext.tool",
            allowedToolNames: [],
            fixture: Fixture(providerTools: ["ext.tool"]),
            error: "Unknown tool: ext.tool",
            isToolNotAllowed: false
        ),
        ThrowingCase(
            label: "destructive tool not allowed raises no request",
            toolName: "git.push",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(providerTools: ["git.push"]),
            error: "Unknown tool: git.push",
            isToolNotAllowed: false
        ),
        ThrowingCase(
            label: "coordination tool not allowed",
            toolName: "agent.list",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(),
            error: "The tool 'agent.list' is not enabled for this agent session.",
            isToolNotAllowed: true
        ),
        ThrowingCase(
            label: "coordination tool with an empty allowlist",
            toolName: "todo.read",
            allowedToolNames: [],
            fixture: Fixture(),
            error: "The tool 'todo.read' is not enabled for this agent session.",
            isToolNotAllowed: true
        ),
        ThrowingCase(
            label: "memory tool not allowed",
            toolName: "memory.read",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(),
            error: "Unknown tool: memory.read",
            isToolNotAllowed: false
        ),
    ]

    @Test(arguments: throwingCases)
    func executeThrowingResultWithoutOuterGuard(_ row: ThrowingCase) async throws {
        let environment = try RoutingEnvironment(fixture: row.fixture)
        defer { environment.remove() }
        let thrown: ThrownError? = try await environment.run { executor in
            do {
                _ = try await executor.executeThrowingResult(
                    sessionID: row.fixture.sessionID,
                    toolCall: Self.toolCall(row.toolName, "{}"),
                    workingDirectory: environment.workspace.workspaceURL,
                    allowedToolNames: row.allowedToolNames
                )
                return nil
            } catch {
                return ThrownError(error)
            }
        }

        let error = try #require(thrown)
        #expect(error.description == row.error)
        #expect(error.isToolNotAllowed == row.isToolNotAllowed)
        #expect(error.isDirectToolError == !row.isToolNotAllowed)
        #expect(await environment.authorizations.toolNames.isEmpty)
        #expect(!environment.featureWasInvoked)
    }

    struct ThrownError: Sendable {
        let description: String
        let isToolNotAllowed: Bool
        let isDirectToolError: Bool

        init(_ error: any Error) {
            description = error.localizedDescription
            if let executorError = error as? DirectToolExecutor.DirectToolExecutorError,
               case .toolNotAllowed = executorError {
                isToolNotAllowed = true
            } else {
                isToolNotAllowed = false
            }
            isDirectToolError = error is DirectToolError
        }
    }

    static func toolCall(_ name: String, _ argumentsJSON: String) -> DirectAgentToolCall {
        let object = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any]
        return DirectAgentToolCall(
            id: UUID().uuidString,
            name: name,
            argumentsObject: object ?? [:],
            argumentsJSON: argumentsJSON
        )
    }
}

/// One isolated executor with the fakes a routing row asks for.
private struct RoutingEnvironment {
    let workspace: MemoryTestWorkspace
    let fixture: DirectToolExecutorRoutingCharacterizationTests.Fixture
    let authorizations = RoutingAuthorizationRecorder()
    let featureURL: URL

    var featureMarkerURL: URL {
        workspace.workspaceURL.appendingPathComponent(".feature-invoked")
    }

    var featureWasInvoked: Bool {
        FileManager.default.fileExists(atPath: featureMarkerURL.path)
    }

    init(fixture: DirectToolExecutorRoutingCharacterizationTests.Fixture) throws {
        self.fixture = fixture
        workspace = try MemoryTestWorkspace()
        featureURL = workspace.rootURL.appendingPathComponent("feature")
        try "alpha\n".write(
            to: workspace.workspaceURL.appendingPathComponent("a.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "delete me\n".write(
            to: workspace.workspaceURL.appendingPathComponent("gone.txt"),
            atomically: true,
            encoding: .utf8
        )
        // Invoked as `feature --invoke <tool> --working-directory <path>`.
        try """
        #!/bin/sh
        cat >/dev/null
        touch "$4/.feature-invoked"
        printf '{"ok":true,"output":"feature-handled:%s"}\\n' "$2"
        """.write(to: featureURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: featureURL.path
        )
    }

    func remove() {
        workspace.remove()
    }

    func run<T: Sendable>(
        _ body: (DirectToolExecutor) async throws -> T
    ) async throws -> T {
        try await workspace.withIsolatedSupport {
            let features: [SwiftFeatureBundle]
            if fixture.featureTools.isEmpty, fixture.featureAliases.isEmpty {
                features = []
            } else {
                features = [
                    SwiftFeatureBundle(
                        id: "routing-fixture",
                        executableURL: featureURL,
                        tools: fixture.featureTools.map(Self.descriptor),
                        toolNameAliases: fixture.featureAliases
                    )
                ]
            }

            let mcpRuntime = DirectMCPToolRuntime()
            var remoteExecutor: RemoteMCPToolExecutor?
            if !fixture.mcpTools.isEmpty {
                let executor = RemoteMCPToolExecutor(
                    configuration: MCPServerConfiguration(
                        executablePath: "/usr/bin/false",
                        arguments: [],
                        environment: [:]
                    ),
                    toolNamePrefix: "remote."
                )
                _ = await mcpRuntime.installBorrowedExternalExecutor(
                    name: "remote",
                    executor: executor,
                    tools: fixture.mcpTools.map(Self.descriptor)
                )
                remoteExecutor = executor
            }

            let recorder = authorizations
            let decision = fixture.authorization == .approve
            let borrowedHandler: AgentBorrowedToolExecutor = { @Sendable call in
                "borrowed-handled:\(call.name)"
            }
            let borrowed: AgentBorrowedToolExecutor? = fixture.borrowedSubAgentExecutor
                ? borrowedHandler
                : nil
            let executor = DirectToolExecutor(
                authorizationHandler: { request in
                    await recorder.append(request.toolName)
                    return decision
                },
                mcpRuntime: mcpRuntime,
                swiftFeatureRuntime: SwiftFeatureRuntime(features: features),
                borrowedSubAgentToolExecutor: borrowed,
                subAgentContextualBackendFactory: { _ in SwiftFeatureTestAgentRuntimeBackend() }
            )
            if !fixture.providerTools.isEmpty {
                await executor.updateToolProviders([
                    AgentToolProvider(
                        tools: fixture.providerTools.map(Self.descriptor),
                        executor: { call in "provider-handled:\(call.name)" }
                    )
                ])
            }

            let value: T
            do {
                value = try await body(executor)
            } catch {
                await executor.shutdown()
                await remoteExecutor?.disconnect()
                throw error
            }
            await executor.shutdown()
            await remoteExecutor?.disconnect()
            return value
        }
    }

    private static func descriptor(_ name: String) -> ToolDescriptor {
        ToolDescriptor(
            name: name,
            description: "Routing fixture.",
            inputSchema: #"{"type":"object","properties":{}}"#
        )
    }
}

private actor RoutingAuthorizationRecorder {
    private(set) var toolNames: [String] = []

    func append(_ toolName: String) {
        toolNames.append(toolName)
    }
}
