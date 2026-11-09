//
//  ToolAllowlistCharacterizationTests.swift
//  ZenCODE
//
//  Pins the allowlist matching of the three places that apply the
//  "exact name, or an entry ending in '.' that prefixes the name" rule:
//  `DirectToolExecutor.isAllowed` (which also resolves coordination aliases
//  and treats nil/empty specially), MCP discovery, and the system prompt.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct ToolAllowlistCharacterizationTests {
    struct MatchCase: Sendable, CustomTestStringConvertible {
        let toolName: String
        let allowedToolNames: Set<String>?
        /// `DirectToolExecutor.isAllowed(_:allowedToolNames:)`.
        let isAllowed: Bool
        /// `DirectMCPToolRuntime.toolName(_:isAllowedBy:)`; nil when the
        /// allowlist is nil, which that function does not accept.
        let mcp: Bool?

        var testDescription: String {
            let list = allowedToolNames.map { "\($0.sorted())" } ?? "nil"
            return "\(toolName) in \(list)"
        }
    }

    static let matchCases: [MatchCase] = [
        // nil and empty allowlists.
        MatchCase(toolName: "local.readFile", allowedToolNames: nil, isAllowed: true, mcp: nil),
        MatchCase(toolName: "agent.spawn", allowedToolNames: nil, isAllowed: true, mcp: nil),
        MatchCase(toolName: "figma.get_code", allowedToolNames: nil, isAllowed: true, mcp: nil),
        MatchCase(toolName: "local.readFile", allowedToolNames: [], isAllowed: false, mcp: false),
        MatchCase(toolName: "agent.create", allowedToolNames: [], isAllowed: false, mcp: false),
        // Exact names.
        MatchCase(toolName: "local.readFile", allowedToolNames: ["local.readFile"], isAllowed: true, mcp: true),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["local.writeFile"], isAllowed: false, mcp: false),
        MatchCase(toolName: "", allowedToolNames: [""], isAllowed: true, mcp: true),
        MatchCase(toolName: "local.", allowedToolNames: ["local."], isAllowed: true, mcp: true),
        // Prefix entries: only an entry ending in "." is a prefix.
        MatchCase(toolName: "local.readFile", allowedToolNames: ["local."], isAllowed: true, mcp: true),
        MatchCase(toolName: "local.exec.extra", allowedToolNames: ["local."], isAllowed: true, mcp: true),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["local"], isAllowed: false, mcp: false),
        MatchCase(toolName: "local", allowedToolNames: ["local."], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["loc."], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["loc"], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["local.readFile."], isAllowed: false, mcp: false),
        MatchCase(toolName: ".hidden", allowedToolNames: ["."], isAllowed: true, mcp: true),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["."], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["git.", "local."], isAllowed: true, mcp: true),
        // Exact and prefix matching is case-sensitive.
        MatchCase(toolName: "LOCAL.readFile", allowedToolNames: ["local."], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readFile", allowedToolNames: ["LOCAL."], isAllowed: false, mcp: false),
        MatchCase(toolName: "local.readfile", allowedToolNames: ["local.readFile"], isAllowed: false, mcp: false),
        // Sub-agent aliases resolve to the canonical grant only in isAllowed.
        MatchCase(toolName: "agent.create", allowedToolNames: ["agent.create"], isAllowed: true, mcp: true),
        MatchCase(toolName: "agent.spawn", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "agent_spawn", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "subagent.create", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "tool_agent_create", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "agents.wait.2", allowedToolNames: ["agent.wait"], isAllowed: true, mcp: false),
        MatchCase(toolName: "agent_send", allowedToolNames: ["agent.message"], isAllowed: true, mcp: false),
        MatchCase(toolName: "external.agent.create", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        // Alias resolution is case-insensitive, unlike exact/prefix matching.
        MatchCase(toolName: "AGENT.SPAWN", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "Agent.Create", allowedToolNames: ["agent.create"], isAllowed: true, mcp: false),
        MatchCase(toolName: "agent.create", allowedToolNames: ["Agent.Create"], isAllowed: false, mcp: false),
        // Aliases are never applied to allowlist entries.
        MatchCase(toolName: "agent.create", allowedToolNames: ["agent_spawn"], isAllowed: false, mcp: false),
        MatchCase(toolName: "agent.create", allowedToolNames: ["agent.spawn"], isAllowed: false, mcp: false),
        MatchCase(toolName: "agent_spawn", allowedToolNames: ["agent_spawn"], isAllowed: true, mcp: true),
        // A prefix grant does not extend to aliases of names it covers.
        MatchCase(toolName: "agent_spawn", allowedToolNames: ["agent."], isAllowed: false, mcp: false),
        MatchCase(toolName: "tasks_list", allowedToolNames: ["tasks."], isAllowed: false, mcp: false),
        // Todo and task coordination aliases.
        MatchCase(toolName: "todo_update", allowedToolNames: ["todo.write"], isAllowed: true, mcp: false),
        MatchCase(toolName: "todo.update", allowedToolNames: ["todo.write"], isAllowed: true, mcp: false),
        MatchCase(toolName: "todo.read", allowedToolNames: ["todo."], isAllowed: true, mcp: true),
        MatchCase(toolName: "tasks_update", allowedToolNames: ["tasks.update"], isAllowed: true, mcp: false),
        MatchCase(toolName: "tasks.stop", allowedToolNames: ["tasks.cancel"], isAllowed: true, mcp: false),
        MatchCase(toolName: "task.update", allowedToolNames: ["tasks.update"], isAllowed: false, mcp: false),
        MatchCase(toolName: "todo_update", allowedToolNames: ["tasks.update"], isAllowed: false, mcp: false),
        // MCP and feature names.
        MatchCase(toolName: "figma.get_code", allowedToolNames: ["figma."], isAllowed: true, mcp: true),
        MatchCase(toolName: "figma.get_code", allowedToolNames: ["figma"], isAllowed: false, mcp: false),
        MatchCase(toolName: "figma.get_code", allowedToolNames: ["figma.get_code"], isAllowed: true, mcp: true),
        MatchCase(toolName: "git.commit", allowedToolNames: ["git."], isAllowed: true, mcp: true),
        MatchCase(toolName: "git.commit", allowedToolNames: ["git"], isAllowed: false, mcp: false),
        MatchCase(toolName: "git.commit", allowedToolNames: ["git.commit"], isAllowed: true, mcp: true),
        MatchCase(toolName: "remote.tool", allowedToolNames: ["remote."], isAllowed: true, mcp: true),
        MatchCase(
            toolName: "generated.token",
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            isAllowed: false,
            mcp: false
        ),
    ]

    @Test(arguments: matchCases)
    func allowlistMatchingTable(_ row: MatchCase) {
        #expect(
            DirectToolExecutor.isAllowed(row.toolName, allowedToolNames: row.allowedToolNames)
                == row.isAllowed
        )
        if let allowedToolNames = row.allowedToolNames, let mcp = row.mcp {
            #expect(
                DirectMCPToolRuntime.toolName(row.toolName, isAllowedBy: allowedToolNames) == mcp
            )
        }
    }

    struct PromptCase: Sendable, CustomTestStringConvertible {
        let allowedToolNames: Set<String>?
        /// `agent.create` is matched.
        let delegation: Bool
        /// `agent.create` and `agent.message` are matched.
        let collaboration: Bool
        /// `tasks.create`, `tasks.list`, and `tasks.update` are matched.
        let taskWorkflow: Bool

        var testDescription: String {
            allowedToolNames.map { "\($0.sorted())" } ?? "nil"
        }
    }

    static let promptCases: [PromptCase] = [
        PromptCase(allowedToolNames: nil, delegation: true, collaboration: true, taskWorkflow: true),
        PromptCase(allowedToolNames: [], delegation: false, collaboration: false, taskWorkflow: false),
        PromptCase(allowedToolNames: ["agent.create"], delegation: true, collaboration: false, taskWorkflow: false),
        PromptCase(allowedToolNames: ["agent.message"], delegation: false, collaboration: false, taskWorkflow: false),
        PromptCase(
            allowedToolNames: ["agent.create", "agent.message"],
            delegation: true,
            collaboration: true,
            taskWorkflow: false
        ),
        PromptCase(allowedToolNames: ["agent."], delegation: true, collaboration: true, taskWorkflow: false),
        PromptCase(allowedToolNames: ["agent"], delegation: false, collaboration: false, taskWorkflow: false),
        PromptCase(allowedToolNames: ["age."], delegation: false, collaboration: false, taskWorkflow: false),
        PromptCase(
            allowedToolNames: ["agent.create.", "agent.message."],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(
            allowedToolNames: ["Agent.Create", "Agent.Message"],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        // Coordination aliases in the allowlist are not resolved by the prompt.
        PromptCase(
            allowedToolNames: ["agent_spawn", "agent_send"],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(
            allowedToolNames: ["agent.spawn", "agent.send"],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(
            allowedToolNames: ["tasks.create", "tasks.list", "tasks.update"],
            delegation: false,
            collaboration: false,
            taskWorkflow: true
        ),
        PromptCase(
            allowedToolNames: ["tasks.create", "tasks.list"],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(allowedToolNames: ["tasks."], delegation: false, collaboration: false, taskWorkflow: true),
        PromptCase(allowedToolNames: ["task."], delegation: false, collaboration: false, taskWorkflow: false),
        PromptCase(
            allowedToolNames: ["tasks_create", "tasks_list", "tasks_update"],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(allowedToolNames: ["agent.", "tasks."], delegation: true, collaboration: true, taskWorkflow: true),
        PromptCase(
            allowedToolNames: ["agent.create", "agent.message", "tasks.create", "tasks.list", "tasks.update"],
            delegation: true,
            collaboration: true,
            taskWorkflow: true
        ),
        PromptCase(
            allowedToolNames: ["local.", "figma.", "git."],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
        PromptCase(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName],
            delegation: false,
            collaboration: false,
            taskWorkflow: false
        ),
    ]

    @Test(arguments: promptCases)
    func promptSectionsFollowAllowlistMatching(_ row: PromptCase) {
        let allowed = row.allowedToolNames
        #expect((SystemPromptBuilder.noProjectAgentsSection(allowedToolNames: allowed) != nil) == row.delegation)
        #expect(
            (SystemPromptBuilder.roleDelegationSection(allowedToolNames: allowed, roles: [.developer]) != nil)
                == row.delegation
        )
        #expect((SystemPromptBuilder.collaborationSection(allowedToolNames: allowed) != nil) == row.collaboration)
        #expect(SystemPromptBuilder.taskWorkflowToolsAreAvailable(allowed) == row.taskWorkflow)

        let orchestration = SystemPromptBuilder.taskOrchestrationSection(allowedToolNames: allowed)
        #expect((orchestration != nil) == row.taskWorkflow)
        if let orchestration {
            #expect(orchestration.contains("When agent.create is unavailable") == !row.delegation)
        }

        let sections = SystemPromptBuilder.standalonePromptSections(
            cwd: "/tmp/workspace",
            agentsSection: nil,
            memorySection: nil,
            memoryToolEnabled: false,
            allowedToolNames: allowed
        )
        #expect(sections.dynamicContext.contains("Task workflow policy:") == row.taskWorkflow)
        #expect(sections.dynamicContext.contains(TaskRecord.collaborationPolicy) == row.collaboration)
    }
}
