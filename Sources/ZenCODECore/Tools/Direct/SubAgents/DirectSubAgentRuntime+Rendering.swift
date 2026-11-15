//
//  DirectSubAgentRuntime+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    /// The feature workflow of a Builder created by `agent.create`, which
    /// mirrors the `/feature` wizard prompt
    /// (`TerminalChat.featureImplementationPrompt`) without its operator
    /// hand-offs. The `id` and `toolName` rules of step 2 are those enforced by
    /// `feature.scaffold` (`SwiftFeatureRuntime.isValidFeatureID`,
    /// `validationErrorsForToolNames`, `validateMCPBridgeToolPrefix`), and the
    /// namespace rule is the one a delegated Builder's scaffold, build,
    /// install, and enable enforce
    /// (`SwiftFeatureRuntime.ensureDelegatedFeatureNamespace`). Step 1 follows
    /// the exposure rule: only a generated, non-catalog feature this Builder
    /// built is exposed (`SwiftFeatureRuntime.recordBuilderOutcome`), and
    /// names the `feature.list` fields that mark a catalog feature
    /// (`SwiftFeatureStatus.source`, and `adoptedFrom`, which the manifest
    /// written for an installed optional feature or a local copy carries).
    static let delegatedFeatureDevelopmentSection = """
    Delegated feature development:
    The agent that created you needs a Swift feature built or changed. No /feature wizard and no operator are at your prompt, so run the whole workflow yourself with the feature.* tools; this section takes precedence over any profile instruction that tells you to hand a step to the operator or to /tools.
    1. Call feature.list first. When a generated feature already provides the capability, reuse it instead of creating a duplicate: change it with feature.edit if needed, then run feature.validate and feature.build on it and make sure it is enabled, because only a feature you built in this delegation is exposed. A bundled or optional catalog feature is never exposed this way: when one of them provides the capability, do not rebuild it and report that the operator has to select it with /tools. feature.list marks a catalog feature with `source` set to `bundled` or, once installed or copied locally, with an `adoptedFrom` value.
    2. For a new tool, call feature.scaffold with `id`, `displayName`, `description`, and `toolName`, and leave the scaffold disabled. The `id` must be new, start with a letter or digit, and contain only letters, digits, `.`, `_`, and `-` (never `..`); the `toolName` must not start with `feature.` or equal the name of a core tool. Give the tool a namespace of its own: `toolName` must not start with a namespace of the core tools (\(coreToolNamespaceList)), and the part of it up to its last dot must not be a namespace of another feature that feature.list reports; a scaffold or build that breaks this rule is refused. Pass `template: "mcp-bridge"` only when you were asked to bridge an MCP server, and only on macOS, the only platform where that template is available: it takes `toolPrefix` in place of `toolName`, and the prefix must not start with `feature.`, `local.`, `search.`, or `text.` and must be a namespace of its own too.
    3. Implement the real behavior in the generated package: tool description, input schema, output contract, and presentation metadata. Keep Swift tools 6.4 and the feature id. Never embed credentials, API keys, tokens, or passwords.
    4. Run feature.validate and fix every error, then feature.build and fix every failure. Only after both succeed, call feature.enable.
    5. A feature you built and enabled is exposed automatically to the session that delegated you, so for it do not tell anyone to use /tools or /feature. End with a report that names the feature id and, for each tool, its name, arguments, and one example call. If you cannot finish, leave the feature disabled and report the blocker.
    """

    /// The namespaces of the core catalog tools, as step 2 of
    /// ``delegatedFeatureDevelopmentSection`` lists them: the namespaces the
    /// delegated namespace check enforces
    /// (`SwiftFeatureRuntime.coreToolNamespaces`, each tool name up to and
    /// including its first dot), sorted, in backticks.
    static let coreToolNamespaceList: String = SwiftFeatureRuntime.coreToolNamespaces
        .map { "`\($0)`" }
        .joined(separator: ", ")

    /// - Parameter responseLanguageSection: The coordinator's locked
    ///   response-language section; `nil` keeps the generic rule.
    public static func systemPrompt(
        name: String,
        taskID: String? = nil,
        taskAttemptID: String? = nil,
        allowedToolNames: Set<String>? = nil,
        selectedProfile: AgentProfile? = nil,
        workingDirectory: URL? = nil,
        responseLanguageSection: String? = nil
    ) -> String {
        var lines = [
            "You are ZenCODE delegated sub-agent \(name).",
            responseLanguageSection?.nilIfBlank
                ?? SystemPromptBuilder.responseLanguageSection(),
            "You are running inside ZenCODE and receive the complete direct toolset available to this process, including local, shell, git, MCP, and sub-agent tools when exposed.",
            "Work only on the delegated scope. Be concise, concrete, and report blockers clearly.",
            "Briefly narrate progress at each meaningful step — what you are inspecting, deciding, building, or validating — rather than working silently. Your intermediate output is streamed to the coordinator, so short status updates let progress be observed incrementally instead of only seeing your final result."
        ]
        if let taskID {
            lines.append("Assigned task: \(taskID)")
            if let taskAttemptID {
                lines.append("Execution attempt: \(taskAttemptID)")
            }
            lines.append("You may use tasks.get/tasks.list to read only this task and its dependencies, and tasks.update only to append progress output to this active attempt.")
            lines.append("You must not change dependencies, reassign work, create nested sub-agents, mutate another task, or validate your own implementation. Final task state is recorded automatically from your outcome.")
            lines.append("After your turn completes you remain in standby while the task graph is active: you can receive and reply to messages from the coordinator and peers in the chat, but you cannot mutate the task graph or resume implementation. For new implementation work the coordinator will open a new attempt.")
        } else if let taskWorkflowSection = SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: allowedToolNames
        ) {
            lines.append(taskWorkflowSection)
        }
        lines.append("Shared chat: when you hit an ambiguity, a decision outside your brief, or a conflict with it, stop and ask with agent.message to=\"coordinator\" and awaitReply=true, and do not proceed on assumptions until the reply arrives. Do not use the chat for progress reports. Unless your role or profile defines its own protocol for questions, follow this rule.")
        // Only an explicit `agent.create` workingDirectory is announced; an
        // inherited directory leaves the prompt unchanged.
        if let workingDirectory {
            lines.append(SystemPromptBuilder.workingDirectorySection(path: workingDirectory.path))
        }
        // A Builder delegated by another agent has no /feature wizard and no
        // operator at its prompt: it gets the whole workflow, right before its
        // profile section so that it takes precedence over it. Only when its
        // grant admits `feature.scaffold`, since otherwise it cannot follow it.
        if selectedProfile?.role == .builder,
           DirectToolExecutor.isAllowed("feature.scaffold", allowedToolNames: allowedToolNames) {
            lines.append(delegatedFeatureDevelopmentSection)
        }
        if let profileSection = selectedProfile?.promptSection,
           !lines.contains(profileSection) {
            lines.append(profileSection)
        }
        return lines.joined(separator: "\n")
    }

    public static func renderSnapshots(
        _ snapshots: [AgentSnapshot],
        includeLatestOutput: Bool = false
    ) -> String {
        guard !snapshots.isEmpty else {
            return "No delegated sub-agents."
        }

        var lines = ["Sub-agents:"]
        for snapshot in snapshots {
            var summary = "- \(snapshot.id) name=\(snapshot.name) status=\(snapshot.status.rawValue) pending=\(snapshot.pending)"
            if let profileName = snapshot.profileName?.nilIfBlank {
                summary += " profile=\(profileName)"
            }
            if let taskID = snapshot.taskID?.nilIfBlank {
                summary += " task=\(taskID)"
            }
            if let ordinal = snapshot.taskAttemptOrdinal {
                summary += " attempt=\(ordinal)"
            }
            if let modelID = snapshot.modelID?.nilIfBlank {
                summary += " model=\(modelID)"
            }
            if let currentToolName = snapshot.currentToolName?.nilIfBlank {
                summary += " tool=\(currentToolName)"
            }
            lines.append(summary)
            if let activity = snapshot.currentActivity?.nilIfBlank {
                lines.append("  activity: \(activity)")
            }
            if includeLatestOutput,
               let latestError = snapshot.latestError?.nilIfBlank {
                lines.append("  latest_error: \(latestError)")
            }
            if includeLatestOutput,
               let latestOutput = snapshot.latestOutput?.nilIfBlank {
                lines.append("  latest_output:")
                lines.append(Self.indented(latestOutput))
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func indented(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    static func agentSortOrder(
        lhs: AgentRecord,
        rhs: AgentRecord
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id < rhs.id
        }
        return lhs.createdAt < rhs.createdAt
    }
}
