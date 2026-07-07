//
//  TerminalChat+Plan.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation

extension TerminalChat {
    /// Read-only canonical tool names a Planner sub-agent may use while preparing
    /// an implementation plan. Planners can inspect the workspace, project
    /// context, memory, web references, and non-mutating Git state, but must not
    /// edit files, run shell commands, or perform mutating Git/memory/task work.
    public static let plannerReadOnlyToolNames: Set<String> = [
        "local.pwd",
        "local.ls",
        "local.readFile",
        "local.readFiles",
        "local.inspectFile",
        "search.glob",
        "search.grep",
        "search.locate",
        "text.head",
        "text.tail",
        "text.sort",
        "text.wc",
        "git.status",
        "git.diff",
        "git.show",
        "git.log",
        "git.branch",
        "git.remote",
        "git.lsFiles",
        "git.grep",
        "git.blame",
        "memory.read",
        "memory.search",
        "todo.read",
        "task.list",
        "task.get",
        "web.search",
        "web.fetch",
    ]

    func handlePlanCommand(_ command: String) -> TerminalSubmittedLineAction {
        let argument = String(command.dropFirst("/plan".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !argument.isEmpty else {
            writeFailureMessage(Self.planMissingGoalMessage)
            return .continueChat
        }

        if !isSubAgentToolEnabled {
            writeFailureMessage(
                """
                ZenCODE: /plan requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        let plannerProfile = plannerProfileForDelegation()

//        writeSystemMessage(
//            "Starting planning pass for requested goal via Planner sub-agents...\n"
//        )

        writeSubmittedPrompt(command)

        return .runHiddenPrompt(
            Self.planDelegationPrompt(
                goal: argument,
                planner: plannerProfile
            )
        )
    }

    static let planMissingGoalMessage =
        "ZenCODE: /plan requires a goal. "
        + "Use /plan <goal> to describe what should be planned.\n"

    /// Resolves the Planner profile used to configure delegated sub-agents.
    /// Prefers a user-configured "Planner" profile from agents.json and falls
    /// back to the built-in default so the command works before any setup.
    func plannerProfileForDelegation() -> AgentProfile {
        let configured = (try? availableAgents()) ?? []
        if let match = configured.first(where: Self.isPlannerProfile) {
            return match
        }
        if let fallback = AgentProfileStore.defaultProfiles().first(where: Self.isPlannerProfile) {
            return fallback
        }
        return AgentProfileStore.defaultProfiles()[0]
    }

    static func isPlannerProfile(_ agent: AgentProfile) -> Bool {
        agent.id.caseInsensitiveCompare(AgentProfileStore.plannerAgentID.uuidString) == .orderedSame
            || agent.name.caseInsensitiveCompare(AgentProfileStore.plannerAgentName) == .orderedSame
    }

    /// Canonical, read-only tool names a Planner sub-agent should receive: the
    /// profile's own tools intersected with the read-only planning allowlist.
    static func plannerSubAgentToolNames(for planner: AgentProfile) -> [String] {
        let profileTools = planner.allowedToolNames()
        let allowed =
            profileTools.isEmpty
            ? plannerReadOnlyToolNames
            : profileTools.intersection(plannerReadOnlyToolNames)
        let resolved = allowed.isEmpty ? plannerReadOnlyToolNames : allowed
        return resolved.sorted()
    }

    static func planDelegationPrompt(
        goal: String,
        planner: AgentProfile
    ) -> String {
        let toolList = plannerSubAgentToolNames(for: planner)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        let goalSection = """
            Planning goal requested by the user: \(goal)
            Plan only this requested activity unless the conversation clearly provides \
            required constraints.
            """

        return """
            You are the director of this planning pass. Stay on your current agent profile: \
            do not switch profiles. Delegate the actual planning to Planner sub-agents via \
            sub-agent tools, then read their plans and produce one consolidated \
            implementation plan.

            \(goalSection)

            Delegation rules:
            - Create at least one sub-agent with agent.create using role "Planner" and \
            isolationMode "report" (read-only; it must not edit files or run mutating \
            commands).
            - Restrict each Planner to this read-only planning toolset by passing \
            toolNames: [\(toolList)].
            - When the activity can be partitioned into independent planning areas (for \
            example files/modules to inspect, requirements, tests, risks, migration steps, \
            or docs), spawn multiple Planners in parallel in a single agent.create call. \
            If the activity is small or cannot be partitioned cleanly, a single Planner is \
            fine.
            - Give each Planner a focused prompt describing its assigned planning subset. \
            Ask Planners to inspect only what is needed to make the plan concrete.
            - Ask Planners to report: likely files/areas to touch, implementation phases, \
            dependencies, risks, edge cases, test/validation strategy, open questions, and \
            a recommended order of work.

            After delegating:
            - Wait for the Planners to finish with agent.wait.
            - Read and consolidate their plans into one actionable plan, removing \
            duplicates and resolving conflicts.
            - The final plan must support this workflow loop: /plan -> implementation work \
            -> /review -> corrections until the work is complete.
            - Do not edit any files yourself in this planning turn. Present the plan, the \
            expected validation, and where /review should be run after implementation.
            - The final planning summary must follow the session response language from \
            the system prompt. Do not answer in English just because this internal planning \
            prompt is written in English.
            """
    }
}
