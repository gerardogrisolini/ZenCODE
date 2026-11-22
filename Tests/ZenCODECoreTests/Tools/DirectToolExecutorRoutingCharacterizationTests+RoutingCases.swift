//
//  DirectToolExecutorRoutingCharacterizationTests+RoutingCases.swift
//  ZenCODE
//
//  The routing table of the direct tool executor characterization tests: one
//  row per combination of tool, allowlist, ownership, provider and operator
//  decision.
//

import FeatureMCPBridgeKit
import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectToolExecutorRoutingCharacterizationTests {
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
            allowed: ["local.read"],
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
            "local.read, nil allowlist", "local.read", #"{"path":"a.txt"}"#,
            allowed: nil,
            expect: .contains("alpha")
        ),
        row(
            "local.read, prefix grant", "local.read", #"{"path":"a.txt"}"#,
            allowed: ["local."],
            expect: .contains("alpha")
        ),
        row(
            "local.read, grant without dot", "local.read", #"{"path":"a.txt"}"#,
            allowed: ["local"],
            expect: notEnabled("local.read"),
            status: .permissionDenied
        ),
        row(
            "local.read, partial prefix grant", "local.read", #"{"path":"a.txt"}"#,
            allowed: ["loc."],
            expect: notEnabled("local.read"),
            status: .permissionDenied
        ),
        row(
            "local.read, uppercase name", "LOCAL.readFile", #"{"path":"a.txt"}"#,
            allowed: ["local."],
            expect: notEnabled("LOCAL.readFile"),
            status: .permissionDenied
        ),
        row(
            "local.read claimed by feature and provider, directly allowed", "local.read",
            #"{"path":"a.txt"}"#,
            allowed: ["local.read"],
            Fixture(featureAliases: ["local.read"], providerTools: ["local.read"]),
            expect: .contains("alpha")
        ),
        row(
            "local.read claimed by a feature, feature.tools only", "local.read",
            #"{"path":"a.txt"}"#,
            allowed: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            Fixture(featureAliases: ["local.read"]),
            expect: .exact("feature-handled:local.read"),
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
            "local.delete outside the workspace denied", "local.delete", #"{"path":"../gone.txt"}"#,
            allowed: nil,
            Fixture(authorization: .deny),
            expect: .contains("Operation cancelled."),
            status: .permissionDenied,
            requests: ["local.delete"]
        ),
        row(
            "local.delete outside the workspace approved", "local.delete", #"{"path":"../gone.txt"}"#,
            allowed: nil,
            expect: .contains("Path does not exist"),
            requests: ["local.delete"]
        ),
        row(
            "local.delete inside the workspace is not gated", "local.delete", #"{"path":"gone.txt"}"#,
            allowed: nil,
            expect: .contains("Deleted ")
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
}
