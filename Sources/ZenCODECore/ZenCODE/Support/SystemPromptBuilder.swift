//
//  SystemPromptBuilder.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct SystemPromptRequest: Sendable {
    public let baseSection: String
    public let workingDirectoryPath: String?
    public let preferredLanguageSection: String?
    public let taskContextSection: String?
    public let workflowSection: String?
    public let agentsSection: String?
    public let memorySection: String?
    public let figmaSection: String?
    public let turnClosingInstruction: String
    public let selectedSkillSection: String?

    public init(
        baseSection: String,
        workingDirectoryPath: String? = nil,
        preferredLanguageSection: String? = nil,
        taskContextSection: String? = nil,
        workflowSection: String? = nil,
        agentsSection: String? = nil,
        memorySection: String? = nil,
        figmaSection: String? = nil,
        turnClosingInstruction: String,
        selectedSkillSection: String? = nil
    ) {
        self.baseSection = baseSection
        self.workingDirectoryPath = workingDirectoryPath
        self.preferredLanguageSection = preferredLanguageSection
        self.taskContextSection = taskContextSection
        self.workflowSection = workflowSection
        self.agentsSection = agentsSection
        self.memorySection = memorySection
        self.figmaSection = figmaSection
        self.turnClosingInstruction = turnClosingInstruction
        self.selectedSkillSection = selectedSkillSection
    }
}

public enum SystemPromptBuilder {
    public static func defaultAgentInstructions(memoryToolEnabled: Bool = true) -> String {
        joined([
            standaloneBaseSection(memoryToolEnabled: memoryToolEnabled),
            taskOrchestrationSection(allowedToolNames: nil),
            standaloneLanguageSection,
            turnClosingSection(instruction: standaloneTurnClosingInstruction)
        ])
    }

    public static func prompt(_ request: SystemPromptRequest) -> String {
        joined([
            request.baseSection,
            request.workingDirectoryPath.map(workingDirectorySection(path:)),
            request.taskContextSection,
            request.workflowSection,
            request.agentsSection,
            request.memorySection,
            request.figmaSection,
            request.selectedSkillSection,
            request.preferredLanguageSection,
            turnClosingSection(instruction: request.turnClosingInstruction)
        ])
    }

    public static func standalonePrompt(
        cwd: String,
        agentsSection: String?,
        memorySection: String?,
        memoryToolEnabled: Bool,
        allowedToolNames: Set<String>? = nil,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil
    ) -> String {
        prompt(
            SystemPromptRequest(
                baseSection: standaloneBaseSection(memoryToolEnabled: memoryToolEnabled),
                workingDirectoryPath: cwd,
                preferredLanguageSection: responseLanguageSection ?? standaloneLanguageSection,
                workflowSection: taskOrchestrationSection(allowedToolNames: allowedToolNames),
                agentsSection: agentsSection,
                memorySection: memorySection,
                turnClosingInstruction: standaloneTurnClosingInstruction,
                selectedSkillSection: selectedSkillSection
            )
        )
    }

    /// Returns guidance for deliberately using the session task graph only when the
    /// current tool surface can create, inspect, and update that graph.
    public static func taskOrchestrationSection(
        allowedToolNames: Set<String>?
    ) -> String? {
        guard taskWorkflowToolsAreAvailable(allowedToolNames) else {
            return nil
        }

        let delegationInstruction: String
        if agentDelegationIsAvailable(allowedToolNames) {
            delegationInstruction = """
            When you choose to delegate graph work, pass its taskID to agent.create so the \
            assignment and execution attempt are recorded atomically. If you delegate, select \
            the most suitable agent profile and one of its authorized model bindings from the \
            delegatable roster: determine the task type and required tools, then choose the \
            lowest-capability binding that meets the task complexity. Delegate independent \
            runnable tasks together when \
            parallel execution is safe and useful; serialize work that mutates overlapping \
            files or shared state. When a task graph is already active, every delegated agent \
            must use taskID; do not create taskless agents outside that workflow. A `/workflow` \
            graph requires every task to be delegated through agent.create(taskID:); the \
            coordinator cannot start a task attempt directly, although its normal tool grant \
            remains unchanged. For other task graphs, you remain free to execute tasks directly. \
            After a `/workflow` implementation task completes, validate its result. If validation \
            is negative, record the task as failed, call tasks.retry, then claim the new attempt \
            with a new agent.create(taskID:); do not use agent.message to reopen a completed \
            task.
            """
        } else {
            delegationInstruction = """
            When agent.create is unavailable, execute runnable graph work directly only in a \
            task graph that permits coordinator execution, and record its lifecycle with \
            tasks.update. Never create or directly execute work in a `/workflow` graph: it \
            requires a sub-agent claim through agent.create(taskID:).
            """
        }

        return """
        Task workflow policy:
        Before launching multiple delegated agents or beginning work with multiple phases, \
        decide whether the request is a coordinated workflow. Create the session task graph \
        with tasks.create first when work has multiple units, dependencies, concurrent delegation, durable \
        progress, retry, validation, or review requirements. Define the work items together \
        with stable IDs and explicit dependencies (including empty dependencies for \
        independent work), then use tasks.list with runnableOnly=true to choose work and \
        tasks.update to record progress, outcomes, blockers, and validation.

        When defining tasks, prefer a dependency graph that maximizes safe, useful parallelism \
        over a linear sequence. Add an edge only for a real prerequisite, required output or \
        decision, validation ordering, or a shared mutable resource that cannot be changed \
        safely in parallel. Never serialize tasks merely because they appear in a numbered \
        order. Give independent tasks empty dependencies when parallel execution reduces elapsed \
        time or separates ownership cleanly. Keep work sequential when concurrency offers no \
        meaningful benefit, would create overlapping edits, or adds coordination risk; do not \
        split trivial work solely to manufacture parallelism.

        Complexity: set tasks.create `complexity` (1–10) on every task. \
        \(TaskRecord.complexityRubric). \
        Agent selection policy: \(TaskRecord.agentSelectionPolicy)

        \(delegationInstruction)
        A single self-contained delegation or a short disposable lookup does not require a \
        task graph.
        """
    }

    public static func taskWorkflowToolsAreAvailable(
        _ allowedToolNames: Set<String>?
    ) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return ["tasks.create", "tasks.list", "tasks.update"].allSatisfy {
            tool($0, isAllowedBy: allowedToolNames)
        }
    }

    /// Generates a roster of delegatable agent profiles and their explicitly
    /// authorized model bindings. This keeps role/tool compatibility separate
    /// from routing capability while never exposing a model outside its
    /// configured profile association.
    public static func delegatableAgentsSection(
        agents: [AgentProfile],
        allowedToolNames: Set<String>?
    ) -> String? {
        guard agentDelegationIsAvailable(allowedToolNames) else {
            return nil
        }
        let roster = agents.compactMap { agent -> (AgentProfile, [AgentModelBinding])? in
            let bindings = agent.modelBindings
                .filter { $0.capability != nil }
                .sorted {
                    let lhsCapability = $0.capability ?? 0
                    let rhsCapability = $1.capability ?? 0
                    if lhsCapability != rhsCapability {
                        return lhsCapability < rhsCapability
                    }
                    return $0.modelID.localizedCaseInsensitiveCompare($1.modelID) == .orderedAscending
                }
            return bindings.isEmpty ? nil : (agent, bindings)
        }
        .sorted {
            $0.0.displayName.localizedCaseInsensitiveCompare($1.0.displayName) == .orderedAscending
        }
        guard !roster.isEmpty else {
            return nil
        }

        let lines = roster.flatMap { agent, bindings -> [String] in
            let roleSummary = delegationRoleSummary(for: agent)
            let bindingLines = bindings.compactMap { binding -> String? in
                guard let capability = binding.capability else { return nil }
                let bindingReference = binding.id == binding.modelID
                    ? binding.modelID
                    : "\(binding.modelID) [binding: \(binding.id)]"
                let defaultMarker = binding.id == agent.defaultModelBindingID ? ", default" : ""
                return "  - \(bindingReference) (capability \(capability)/10\(defaultMarker))"
            }
            return ["- \(agent.displayName): \(roleSummary)"] + bindingLines
        }

        return """
        Delegatable agent profiles and authorized model bindings (filter by role and constraints first):
        \(lines.joined(separator: "\n"))
        Agent selection policy: \(TaskRecord.agentSelectionPolicy)
        Pass the selected profile name as `profile` or `agent` and its selected binding id or \
        model id as `model` or `modelID` in agent.create. Give the sub-agent an explicit role \
        and scope. Its effective tools come from the parent grant; `toolNames` can only narrow \
        that grant.
        """
    }

    private static func delegationRoleSummary(for agent: AgentProfile) -> String {
        guard let instructions = agent.instructions?.nilIfBlank else {
            return "No role constraints declared."
        }
        return instructions
            .components(separatedBy: .newlines)
            .compactMap(\.nilIfBlank)
            .first
            ?? "No role constraints declared."
    }

    /// Adds the workflow policy to an existing prompt exactly once. This keeps
    /// restored or caller-provided system prompts current without discarding
    /// their original instructions.
    public static func appendingTaskOrchestrationSection(
        to prompt: String?,
        allowedToolNames: Set<String>?
    ) -> String? {
        guard let normalizedPrompt = prompt?.nilIfBlank,
              let section = taskOrchestrationSection(allowedToolNames: allowedToolNames),
              !normalizedPrompt.contains("Task workflow policy:") else {
            return prompt
        }
        return normalizedPrompt + "\n\n" + section
    }

    public static func selectedSkillSection(skills: [PromptSkill]) -> String? {
        guard !skills.isEmpty else {
            return nil
        }

        let skillPrompt = skills
            .map { skillPromptSection(skill: $0) }
            .joined(separator: "\n\n")

        return """
        Selected skill guidance for this task is supplemental context. Use it when relevant.

        Additional skill guidance selected for this task:
        \(skillPrompt)
        """
    }

    public static func responseLanguageSection(languageName: String? = nil) -> String {
        if let languageName = languageName?.nilIfBlank {
            return """
            Response language:
            The response language for this session is locked to \(languageName). Use \(languageName) for all natural-language replies, including final answers, summaries, review findings, and correction plans, even when the current prompt or an internal slash-command prompt is written in another language. Only change this if the user explicitly asks to change the session response language. Keep code, file paths, API names, tool names, and literal command output unchanged unless translation is explicitly requested.
            """
        }

        return """
        Response language:
        Use the operating system language for all natural-language replies. If the operating system language cannot be determined, fall back to the language of the user's first visible, user-authored prompt in this session. Ignore hidden/internal prompts generated by slash commands when determining the response language. Keep using that session language for later turns even if a later prompt or internal command is written in another language, unless the user explicitly asks to change the session response language. Keep code, file paths, API names, tool names, and literal command output unchanged unless translation is explicitly requested.
        """
    }

    public static func workingDirectorySection(path: String) -> String {
        """
        Current task working directory for local tools:
        - Working directory path: \(path)
        Use this directory as the default root for Shell, Git, local filesystem tools, and persistent project context.
        Do not invent a different local root unless the user explicitly asks for one.
        For relative local paths, make them relative to this directory and do not duplicate the repo root.
        """
    }

    public static func turnClosingSection(instruction: String) -> String {
        """
        Turn-closing rule:
        \(instruction)
        """
    }

    private static func agentDelegationIsAvailable(
        _ allowedToolNames: Set<String>?
    ) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return tool("agent.create", isAllowedBy: allowedToolNames)
    }

    private static func tool(
        _ name: String,
        isAllowedBy allowedToolNames: Set<String>
    ) -> Bool {
        allowedToolNames.contains(name)
            || allowedToolNames.contains {
                $0.hasSuffix(".") && name.hasPrefix($0)
            }
    }

    private static func standaloneBaseSection(memoryToolEnabled: Bool) -> String {
        let confirmationFiles = ""
//        """
//        6. Before starting file modifications, briefly explain the intended changes, including a concise list of the files or areas you expect to edit and what you expect to change in each one, then ask the user to confirm. Do not modify files until the user confirms.
//        7. When pausing for this confirmation, do not rely on the turn-closing modified-files report as the only file list; the intended edits must be visible before the confirmation question.
//        8. Ask for confirmation when the next step starts file modifications, is destructive, irreversible, or genuinely ambiguous.
//        """

        let toolFamilyText = memoryToolEnabled
            ? "Git, Xcode, Shell, Web, Figma, memory, and delegated sub-agent tools"
            : "Git, Xcode, Shell, Web, Figma and delegated sub-agent tools"
        return """
        You are ZenCODE running as an autonomous CLI/ACP coding agent on the user's machine.

        Tool rules:
        1. Decide whether one of the available tools is needed before answering.
        2. Use the model's native tool-call interface when calling tools; do not print JSON tool-call objects, markdown fences, or XML-style wrappers. Keep any narration as natural-language assistant text, not as serialized tool calls.
        3. Use only exact tool names exposed in this session. Never invent tool names, and do not claim a tool is missing if it is exposed.
        4. Do not ask for routine confirmation to inspect, search, read, or run non-mutating diagnostics when those steps are already implied by the user's request.
        5. For non-trivial tool use, briefly comment before the first tool call in a phase, explaining what you are about to inspect, run, or edit and why. For long or multi-phase work, add concise progress updates at phase boundaries; do not narrate every trivial call, reveal private chain-of-thought, or ask for routine confirmation when diagnostics are implied.
        \(confirmationFiles)

        Coding workflow:
        Prefer concrete tool evidence over assumptions. Search before broad reads, read before edits, and keep edits narrowly scoped to the user's request. When inspecting unfamiliar or large files, prefer compact orientation tools such as `local.inspectFile` and `search.locate`, then read only the specific ranges needed with `local.readFile` offset/limit. Preserve unrelated user changes and do not revert work you did not make. Use \(toolFamilyText) when they are available and relevant. Prefer dedicated non-shell tools for file, text, search, Git, web, Xcode, Figma, memory, and sub-agent operations when those tools are exposed; use shell execution only for work not covered by a dedicated tool. Prefer Xcode-native tools for Apple-project build, test, preview, and diagnostics work when those tools are exposed. Validate important changes with the available build, test, lint, or diagnostic tools when the risk justifies it.
        """
    }

    private static var standaloneLanguageSection: String {
        responseLanguageSection()
    }

    private static var standaloneTurnClosingInstruction: String {
        "Once the requested work is complete and no tool call is needed, stop."
    }

    private static func skillPromptSection(skill: PromptSkill) -> String {
        guard let sourceDirectoryPath = skill.sourceDirectoryPath?.nilIfBlank else {
            return """
            Skill: \(skill.title)
            \(skill.promptBody)
            """
        }

        return """
        Skill: \(skill.title)
        Skill root path: \(sourceDirectoryPath)
        Any relative file paths mentioned in this skill are relative to the skill root above, not to the task working directory. If you need to open one of those files with a local tool, keep the `references/...` or similar subpath under that skill root, or pass the absolute skill file path directly.
        \(skill.promptBody)
        """
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ sections: [String?]) -> String {
        sections
            .compactMap { section in
                guard let section else {
                    return nil
                }

                let normalizedSection = normalized(section)
                return normalizedSection.isEmpty ? nil : normalizedSection
            }
            .joined(separator: "\n\n")
    }
}
