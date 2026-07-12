//
//  DirectSubAgentRuntime+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension DirectSubAgentRuntime {
    public static func systemPrompt(
        name: String,
        role: String,
        isolationMode: IsolationMode,
        taskID: String? = nil,
        taskAttemptID: String? = nil,
        allowedToolNames: Set<String>? = nil
    ) -> String {
        var lines = [
            "You are ZenCODE delegated sub-agent \(name).",
            "Role: \(role)",
            SystemPromptBuilder.responseLanguageSection(),
            "You are running inside ZenCODE and receive the complete direct toolset available to this process, including local, shell, git, MCP, and sub-agent tools when exposed.",
            "Work only on the delegated scope. Be concise, concrete, and report blockers clearly."
        ]
        if let taskID {
            lines.append("Assigned task: \(taskID)")
            if let taskAttemptID {
                lines.append("Execution attempt: \(taskAttemptID)")
            }
            lines.append("You may use task.get/task.list to read only this task and its dependencies, and task.update only to append progress output to this active attempt.")
            lines.append("You must not change dependencies, reassign work, create nested sub-agents, mutate another task, or validate your own implementation. Final task state is recorded automatically from your outcome.")
        } else if let taskWorkflowSection = SystemPromptBuilder.taskOrchestrationSection(
            allowedToolNames: allowedToolNames
        ) {
            lines.append(taskWorkflowSection)
        }
        switch isolationMode {
        case .report:
            lines.append("Isolation mode: report. Investigate, inspect, build, test, review, and summarize, but do not make file edits or other mutating changes.")
        case .implementation:
            lines.append("Isolation mode: implementation. You may edit code, but keep changes narrowly scoped to the delegated task.")
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
            var summary = "- \(snapshot.id) name=\(snapshot.name) role=\(snapshot.role) status=\(snapshot.status.rawValue) pending=\(snapshot.pending) isolation=\(snapshot.isolationMode.rawValue)"
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
                lines.append(Self.indented(Self.truncated(latestOutput, limit: 8_000)))
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func indented(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { "    \($0)" }
            .joined(separator: "\n")
    }

    public static func truncated(
        _ text: String,
        limit: Int
    ) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit)) + "\n... truncated ..."
    }

    public static func agentSortOrder(
        lhs: AgentRecord,
        rhs: AgentRecord
    ) -> Bool {
        if lhs.createdAt == rhs.createdAt {
            return lhs.id < rhs.id
        }
        return lhs.createdAt < rhs.createdAt
    }
}
