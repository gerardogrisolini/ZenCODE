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

    static let routingCases: [RoutingCase] = [
        // local.exec stays in the core runtime whenever it is directly allowed.
        row(
            "local.exec, nil allowlist", "local.exec", #"{"command":"printf core-exec"}"#,
            allowed: nil,
            expect: .contains("stdout:\ncore-exec"),
            requests: ["local.exec"]
        ),
        row(
            "local.exec claimed by a feature, directly allowed", "local.exec",
            #"{"command":"printf core-exec"}"#,
            allowed: ["local.exec"],
            Fixture(featureTools: ["local.exec"]),
            expect: .contains("stdout:\ncore-exec"),
            requests: ["local.exec"]
        ),
        row(
            "local.exec claimed by a feature, feature.tools only", "local.exec",
            #"{"command":"printf core-exec"}"#,
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureTools: ["local.exec"]),
            expect: .exact("feature-handled:local.exec"),
            featureInvoked: true
        ),
        row(
            "local.exec not allowed", "local.exec", #"{"command":"printf core-exec"}"#,
            allowed: ["local.readFile"],
            expect: notEnabled("local.exec"),
            status: .permissionDenied
        ),
        row(
            "local.exec denied by its own gate", "local.exec", #"{"command":"printf core-exec"}"#,
            allowed: ["local.exec"],
            Fixture(authorization: .deny),
            expect: .contains("Command execution cancelled."),
            status: .permissionDenied,
            requests: ["local.exec"]
        ),
        // exec.job.
        row(
            "exec.job list, exact grant", "exec.job", #"{"action":"list"}"#,
            allowed: ["exec.job"],
            expect: .exact(#"No background jobs. Start one with local.exec {"command":"...","background":true}."#)
        ),
        row(
            "exec.job list, prefix grant", "exec.job", #"{"action":"list"}"#,
            allowed: ["exec."],
            expect: .exact(#"No background jobs. Start one with local.exec {"command":"...","background":true}."#)
        ),
        // Core local tools.
        row(
            "local.readFile, nil allowlist", "local.readFile", #"{"path":"a.txt"}"#,
            allowed: nil,
            expect: .contains("alpha")
        ),
        row(
            "local.readFile, prefix grant", "local.readFile", #"{"path":"a.txt"}"#,
            allowed: ["local."],
            expect: .contains("alpha")
        ),
        row(
            "local.readFile, grant without dot", "local.readFile", #"{"path":"a.txt"}"#,
            allowed: ["local"],
            expect: notEnabled("local.readFile"),
            status: .permissionDenied
        ),
        row(
            "local.readFile, partial prefix grant", "local.readFile", #"{"path":"a.txt"}"#,
            allowed: ["loc."],
            expect: notEnabled("local.readFile"),
            status: .permissionDenied
        ),
        row(
            "local.readFile, uppercase name", "LOCAL.readFile", #"{"path":"a.txt"}"#,
            allowed: ["local."],
            expect: notEnabled("LOCAL.readFile"),
            status: .permissionDenied
        ),
        row(
            "local.readFile claimed by feature and provider, directly allowed", "local.readFile",
            #"{"path":"a.txt"}"#,
            allowed: ["local.readFile"],
            Fixture(featureAliases: ["local.readFile"], providerTools: ["local.readFile"]),
            expect: .contains("alpha")
        ),
        row(
            "local.readFile claimed by a feature, feature.tools only", "local.readFile",
            #"{"path":"a.txt"}"#,
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureAliases: ["local.readFile"]),
            expect: .exact("feature-handled:local.readFile"),
            featureInvoked: true
        ),
        // Provider registry.
        row(
            "provider tool", "ext.tool",
            allowed: ["ext.tool"],
            Fixture(providerTools: ["ext.tool"]),
            expect: .exact("provider-handled:ext.tool")
        ),
        row(
            "provider before feature", "dual.tool",
            allowed: ["dual.tool"],
            Fixture(featureTools: ["dual.tool"], providerTools: ["dual.tool"]),
            expect: .exact("provider-handled:dual.tool")
        ),
        row(
            "provider skipped without a direct grant, feature runs", "dual.tool",
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureTools: ["dual.tool"], providerTools: ["dual.tool"]),
            expect: .exact("feature-handled:dual.tool"),
            featureInvoked: true
        ),
        row(
            "provider before MCP", "remote.tool",
            allowed: ["remote."],
            Fixture(providerTools: ["remote.tool"], mcpTools: ["tool"]),
            expect: .exact("provider-handled:remote.tool")
        ),
        row(
            "provider tool not allowed", "ext.tool",
            allowed: ["other.tool"],
            Fixture(providerTools: ["ext.tool"]),
            expect: notEnabled("ext.tool"),
            status: .permissionDenied
        ),
        // Feature management.
        row(
            "feature management", "feature.enable",
            allowed: nil,
            expect: .exact("Tool error: Missing required argument: id"),
            status: .failed
        ),
        row(
            "feature management before a feature claiming its name", "feature.enable",
            allowed: nil,
            Fixture(featureAliases: ["feature.enable"]),
            expect: .exact("Tool error: Missing required argument: id"),
            status: .failed
        ),
        row(
            "feature management is never feature-owned", "feature.enable",
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureAliases: ["feature.enable"]),
            expect: notEnabled("feature.enable"),
            status: .permissionDenied
        ),
        // Features.
        row(
            "feature tool, exact grant", "fx.tool",
            allowed: ["fx.tool"],
            Fixture(featureTools: ["fx.tool"]),
            expect: .exact("feature-handled:fx.tool"),
            featureInvoked: true
        ),
        row(
            "feature tool, prefix grant", "fx.tool",
            allowed: ["fx."],
            Fixture(featureTools: ["fx.tool"]),
            expect: .exact("feature-handled:fx.tool"),
            featureInvoked: true
        ),
        row(
            "feature tool, feature.tools grant", "fx.tool",
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureTools: ["fx.tool"]),
            expect: .exact("feature-handled:fx.tool"),
            featureInvoked: true
        ),
        row(
            "feature tool not allowed", "fx.tool",
            allowed: ["other.tool"],
            Fixture(featureTools: ["fx.tool"]),
            expect: notEnabled("fx.tool"),
            status: .permissionDenied
        ),
        row(
            "feature before MCP", "remote.tool",
            allowed: ["remote.tool"],
            Fixture(featureTools: ["remote.tool"], mcpTools: ["tool"]),
            expect: .exact("feature-handled:remote.tool"),
            featureInvoked: true
        ),
        // MCP.
        row(
            "MCP tool, nil allowlist", "remote.tool",
            allowed: nil,
            Fixture(mcpTools: ["tool"]),
            expect: mcpFailure,
            status: .failed
        ),
        row(
            "MCP tool, prefix grant", "remote.tool",
            allowed: ["remote."],
            Fixture(mcpTools: ["tool"]),
            expect: mcpFailure,
            status: .failed
        ),
        row(
            "MCP tool, feature.tools only", "remote.tool",
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(mcpTools: ["tool"]),
            expect: notEnabled("remote.tool"),
            status: .permissionDenied
        ),
        row(
            "MCP before the coordination fallback", "remote.agent.create",
            allowed: ["remote."],
            Fixture(mcpTools: ["agent.create"]),
            expect: mcpFailure,
            status: .failed
        ),
        // Coordination.
        row(
            "coordination alias with canonical grant", "todo_update", #"{"content":"Keep this todo."}"#,
            allowed: ["todo.write"],
            expect: .contains("Keep this todo.")
        ),
        row(
            "coordination alias with only the raw grant", "agent_spawn",
            allowed: ["agent_spawn"],
            expect: notEnabled("agent_spawn"),
            status: .permissionDenied
        ),
        row(
            "coordination alias with prefix grant", "agent_spawn",
            allowed: ["agent."],
            expect: notEnabled("agent_spawn"),
            status: .permissionDenied
        ),
        row(
            "external prefix cannot reach a core coordination tool", "external.agent.create",
            allowed: ["external."],
            expect: notEnabled("external.agent.create"),
            status: .permissionDenied
        ),
        row(
            "external provider before the coordination fallback", "external.agent.create",
            allowed: ["external."],
            Fixture(providerTools: ["external.agent.create"]),
            expect: .exact("provider-handled:external.agent.create")
        ),
        row(
            "sub-agent runtime", "agent.list",
            allowed: nil,
            expect: .exact("No delegated sub-agents.")
        ),
        row(
            "sub-agent runtime, uppercase alias", "Agent.List",
            allowed: ["agent.list"],
            expect: .exact("No delegated sub-agents.")
        ),
        row(
            "borrowed sub-agent executor", "agent.list",
            allowed: ["agent."],
            Fixture(borrowedSubAgentExecutor: true),
            expect: .exact("borrowed-handled:agent.list")
        ),
        row(
            "borrowed sub-agent executor receives the raw alias", "agent_list",
            allowed: ["agent.list"],
            Fixture(borrowedSubAgentExecutor: true),
            expect: .exact("borrowed-handled:agent_list")
        ),
        row(
            "todo stays local with a borrowed executor", "todo.read",
            allowed: nil,
            Fixture(borrowedSubAgentExecutor: true),
            expect: .exact("No todos.")
        ),
        row(
            "task adapter", "tasks.list",
            allowed: ["tasks.list"],
            expect: .exact("No tasks.")
        ),
        row(
            "task alias without a prefix extension", "tasks_list",
            allowed: ["tasks."],
            expect: notEnabled("tasks_list"),
            status: .permissionDenied
        ),
        row(
            "tasks.cancel without a session", "tasks.cancel", #"{"id":"missing"}"#,
            allowed: ["tasks.cancel"],
            Fixture(sessionID: nil),
            expect: .exact(
                "Tool error: tasks.cancel requires an explicit sessionID; refusing to use a fallback task graph."
            ),
            status: .failed
        ),
        // Memory.
        row(
            "memory tool", "memory.read",
            allowed: ["memory.read"],
            expect: .exact("No memory entries matched.")
        ),
        row(
            "memory tool, feature.tools only", "memory.read",
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            expect: notEnabled("memory.read"),
            status: .permissionDenied
        ),
        // Destructive gate.
        row(
            "local.delete denied", "local.delete", #"{"path":"gone.txt"}"#,
            allowed: nil,
            Fixture(authorization: .deny),
            expect: .contains("Operation cancelled."),
            status: .permissionDenied,
            requests: ["local.delete"]
        ),
        row(
            "local.delete approved", "local.delete", #"{"path":"gone.txt"}"#,
            allowed: nil,
            expect: .contains("Deleted "),
            requests: ["local.delete"]
        ),
        row(
            "git.push approved without an implementation", "git.push", #"{"remote":"origin"}"#,
            allowed: ["git.push"],
            expect: unknown("git.push"),
            status: .failed,
            requests: ["git.push"]
        ),
        row(
            "git.push denied without an implementation", "git.push", #"{"remote":"origin"}"#,
            allowed: ["git.push"],
            Fixture(authorization: .deny),
            expect: .contains("Operation cancelled."),
            status: .permissionDenied,
            requests: ["git.push"]
        ),
        row(
            "git.push dry run is not gated", "git.push", #"{"dryRun":true}"#,
            allowed: ["git.push"],
            expect: unknown("git.push"),
            status: .failed
        ),
        row(
            "git.push feature alias via feature.tools, approved", "git.push", #"{"remote":"origin"}"#,
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureAliases: ["git.push"]),
            expect: .exact("feature-handled:git.push"),
            requests: ["git.push"],
            featureInvoked: true
        ),
        row(
            "git.push feature alias via feature.tools, denied", "git.push", #"{"remote":"origin"}"#,
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureAliases: ["git.push"], authorization: .deny),
            expect: .contains("Operation cancelled."),
            status: .permissionDenied,
            requests: ["git.push"]
        ),
        row(
            "git.push provider, approved", "git.push", #"{"remote":"origin"}"#,
            allowed: ["git."],
            Fixture(providerTools: ["git.push"]),
            expect: .exact("provider-handled:git.push"),
            requests: ["git.push"]
        ),
        row(
            "git.push not allowed raises no request", "git.push", #"{"remote":"origin"}"#,
            allowed: ["git.commit"],
            Fixture(providerTools: ["git.push"]),
            expect: notEnabled("git.push"),
            status: .permissionDenied
        ),
        row(
            "desktop.run terminate_app denied", "desktop.run", #"{"action":"terminate_app","bundle_id":"com.example"}"#,
            allowed: ["desktop.run"],
            Fixture(featureTools: ["desktop.run"], authorization: .deny),
            expect: .contains("Operation cancelled."),
            status: .permissionDenied,
            requests: ["desktop.run"]
        ),
        row(
            "desktop.run screenshot is not gated", "desktop.run", #"{"action":"screenshot"}"#,
            allowed: ["desktop.run"],
            Fixture(featureTools: ["desktop.run"]),
            expect: .exact("feature-handled:desktop.run"),
            featureInvoked: true
        ),
        // Unknown tools.
        row(
            "unknown tool, nil allowlist", "nope.tool",
            allowed: nil,
            expect: unknown("nope.tool"),
            status: .failed
        ),
        row(
            "unknown tool, not allowed", "nope.tool",
            allowed: ["other.tool"],
            expect: notEnabled("nope.tool"),
            status: .permissionDenied
        ),
    ]

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
            toolName: "local.readFile",
            allowedToolNames: ["other.tool"],
            fixture: Fixture(),
            error: "Unknown tool: local.readFile",
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
                subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
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
