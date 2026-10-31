//
//  ChatSessionNoticeText+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The wording of the shared slash commands (`/help`, `/plan`, `/goal`,
/// `/review`, `/tasks`, `/changes`, `/undo`, `/artifacts`, `/open`,
/// `/attach`), character for character what the terminal wrote before the
/// commands moved here.
///
/// The `/plan` and `/goal` constants, the task description, the `/attach`
/// texts (usage, delete usage, attachment line), and the `/open` candidate
/// list live here, and the terminal chat's `static` members of the same name
/// forward to them, so each wording has one copy. Texts the planning commands
/// share with ACP stay in ``PlanningCommandKernel`` and are called from there.
extension ChatSessionNoticeText {
    // MARK: - Help

    /// The `/help` text: the opening line, the help line of each command the
    /// agent can use, and the live-chat, consent, and editing lines.
    static func helpText(commandHelp: [String]) -> String {
        var lines = [
            "Type a prompt and press return."
        ]
        lines.append(contentsOf: commandHelp)
        lines.append(contentsOf: [
            "Live chat: @coordinator <message>, @all <message>, or an @agent-name handle.",
            "Ctrl+G toggles default/full access for local.exec approvals in the interactive panel.",
            "Editing: Ctrl+A/Ctrl+E line start/end, Alt+</Alt+> draft start/end, "
                + "Alt+←/→ (or ESC b / ESC f) word motion.",
        ])
        return lines.joined(separator: "\n") + "\n\n"
    }

    // MARK: - /plan

    static let planMissingGoalMessage =
        "ZenCODE: /plan requires a goal. Use /plan <goal> to describe what should "
        + "be planned, or a subcommand: save, load, list, delete, status, approve, clear.\n"

    static let planUnavailableForApprovalMessage =
        "ZenCODE: no completed plan is available to approve. "
        + "Run /plan <goal> and wait for it to finish successfully.\n"

    static let planDiscussionBlocksMutationMessage =
        "ZenCODE: finish the current Planner clarification or Goal request, or use /plan clear before "
        + "approving, saving, or loading a plan.\n"

    static let planUnavailableForSavingMessage =
        "ZenCODE: no plan is available to save. Run /plan <goal>, or ask an agent "
        + "to produce a plan before using /plan save.\n"

    static let savedPlanUnavailableMessage =
        "ZenCODE: no saved plan is available for this project. Use /plan save first.\n"

    static let savedPlansAllTerminalMessage =
        "ZenCODE: every saved plan for this project is already completed. "
        + "Use /plan list to review them or /plan delete <plan|all> to remove them.\n"

    static let planDeleteUsageMessage =
        "ZenCODE: /plan delete requires a plan id, a unique id prefix, or all. "
        + "Use /plan list to review saved plans.\n"

    /// `/plan` or `/review` with the sub-agents tool group off.
    static func subAgentToolsRequiredText(command: String) -> String {
        "ZenCODE: \(command) requires the sub-agents tool group. "
            + "Enable it from the ZenCODE TUI with /tools (or switch to an agent that includes it) and try again.\n"
    }

    // MARK: - /goal

    static let workflowMissingGoalMessage =
        "ZenCODE: /goal requires a goal. "
        + "Use /goal <goal> to describe the outcome to achieve.\n"

    static let workflowActivePlanMessage =
        "ZenCODE: /goal cannot start while an active plan or planning discussion exists. "
        + "Finish it or use /plan clear before starting a workflow.\n"

    static func workflowAlreadyActiveMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "ZenCODE: a goal workflow is already running (\(graphID), "
            + "\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") still open). "
            + "Reply in chat to continue it while it is waiting for you, "
            + "review it with /tasks, "
            + "or run /tasks clear before starting another /goal.\n"
    }

    static func workflowStillOpenMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" asked a question and is still open "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open). "
            + "Your next message answers it on the same task graph; "
            + "use /tasks to review or /tasks clear to stop it.\n"
    }

    /// Notice for a workflow turn that ended without the explicit clarification
    /// block. The graph stays open, but nothing is waiting for a reply.
    static func workflowOpenWithoutQuestionMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" is still open "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open) "
            + "but it is not waiting for an answer, so your next message is an ordinary "
            + "message. Use /tasks to review it or /tasks clear to stop it.\n"
    }

    /// Notice for a failed or cancelled workflow turn whose graph was preserved.
    static func workflowRecoverableFailureMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" was interrupted and its task graph was kept "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open). "
            + "Your next message resumes it on the same task graph; "
            + "use /tasks to review or /tasks clear to stop it.\n"
    }

    // MARK: - /tasks

    /// `/tasks show`: one task as Markdown. Plain Markdown, so a channel
    /// that renders Markdown gets the same text the terminal writes.
    static func taskDetailMarkdown(_ view: TaskRecordView) -> String {
        let task = view.task
        var lines = [
            "## Task `\(task.id)`",
            "",
            "**Title:** \(escapedTaskMarkdown(task.title))",
            "",
            "**Status:** `\(task.status.rawValue)` · **priority:** `\(task.priority.rawValue)` · **complexity:** `\(task.complexity)/10` · **revision:** \(task.revision)",
            "",
            "**Runnable:** `\(view.isRunnable)`",
        ]
        if let reason = view.blockedReason { lines.append("**Runnable reason:** \(escapedTaskMarkdown(reason))") }
        if let details = task.details { lines.append("\n\(escapedTaskMarkdown(details))") }
        if !task.dependsOn.isEmpty { lines.append("\n**Dependencies:** " + task.dependsOn.map { "`\($0)`" }.joined(separator: ", ")) }
        if !view.dependents.isEmpty { lines.append("\n**Dependents:** " + view.dependents.map { "`\($0)`" }.joined(separator: ", ")) }
        if !task.acceptanceCriteria.isEmpty {
            lines.append("\n### Acceptance criteria")
            lines.append(contentsOf: task.acceptanceCriteria.map { "- \(escapedTaskMarkdown($0))" })
        }
        if !task.attempts.isEmpty {
            lines.append("\n### Attempts")
            for attempt in task.attempts {
                let agent = attempt.agentID.map { " · agent `\($0)`" } ?? ""
                lines.append("- **#\(attempt.ordinal)** `\(attempt.status.rawValue)`\(agent) · `\(attempt.id)`")
                if let output = attempt.output { lines.append("  - output: \(escapedTaskMarkdown(output))") }
                if let error = attempt.error { lines.append("  - error: \(escapedTaskMarkdown(error))") }
            }
        }
        if let result = task.result, !result.evidence.isEmpty {
            lines.append("\n### Evidence")
            lines.append(contentsOf: result.evidence.map { evidence in
                let location = evidence.location.map { " (`\($0)`)" } ?? ""
                return "- `\(evidence.kind)`\(location): \(escapedTaskMarkdown(evidence.summary))"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Task text on one line: line breaks become spaces.
    static func escapedTaskMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    // MARK: - /artifacts

    /// The plain fallback of ``ChatSessionNotice/fileArtifacts(_:)``: the
    /// layout of the terminal's `/artifacts` Markdown (title, one heading per
    /// turn, one line per file with its counts and explanation) without the
    /// diffs, which only the terminal's renderers draw.
    static func fileArtifactsFallbackText(_ turns: [SessionFileArtifactHistory.Turn]) -> String {
        var lines = ["", "🪬 Artifacts"]
        for turn in turns {
            let count = turn.artifacts.count == 1 ? "1 file" : "\(turn.artifacts.count) files"
            lines.append("")
            lines.append("### Turn \(turn.number) — \(count)")
            for artifact in turn.artifacts {
                lines.append("")
                lines.append(fileArtifactMetadata(artifact))
                if let explanation = artifact.explanation?.nilIfBlank {
                    lines.append("Explanation: \(explanation)")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The Markdown line that names an artifact: status, path, counts, and
    /// whether it is binary.
    static func fileArtifactMetadata(_ artifact: FileChangeArtifact) -> String {
        let path = artifact.displayPath.nilIfBlank ?? artifact.absolutePath
        let displayedPath = path.nilIfBlank ?? "(unknown path)"
        let counts = artifact.hasLineCounts ? "  +\(artifact.additions) -\(artifact.deletions)" : ""
        let binary = artifact.isBinary ? " (binary)" : ""
        return "**\(artifact.status.rawValue) `\(markdownInlineCode(displayedPath))`**\(counts)\(binary)"
    }

    private static func markdownInlineCode(_ text: String) -> String {
        text.replacingOccurrences(of: "`", with: "\\`")
    }

    // MARK: - /open

    /// The `/open` list of the files and URLs the conversation mentions.
    static func openCandidateListText(_ candidates: [ChatOpenCandidate]) -> String {
        let lines = candidates.enumerated().map { index, candidate -> String in
            let kind = candidate.kind == .url ? "url" : "file"
            return "  \(index + 1). \(candidate.display) (\(kind))"
        }
        return """
        Files and URLs in this conversation:
        \(lines.joined(separator: "\n"))

        """
    }

    // MARK: - /attach

    static let attachmentUsage = """
        Usage: /attach                    Open the terminal attachment picker
               /attach <image-or-video-file> [file ...]
               /attach list
               /attach delete [all|attachment-number]

        """

    static let attachmentDeleteUsage = "Usage: /attach delete [all|attachment-number]\n"

    static let noPendingAttachmentsText = "No pending attachments.\n"

    /// The numbered list of the attachments staged for the next prompt; an
    /// empty list reads as no pending attachments.
    static func pendingAttachmentsText(_ attachments: [AgentRuntimeAttachment]) -> String {
        guard !attachments.isEmpty else {
            return noPendingAttachmentsText
        }
        let lines = attachments.enumerated().map { index, attachment in
            attachmentLine(number: index + 1, attachment: attachment)
        }
        return """
            Pending attachments:
            \(lines.joined(separator: "\n"))
            Send a prompt to include them, or press return on an empty prompt.

            """
    }

    /// One numbered line of the staged-attachment list: the file name and, in
    /// parentheses, the kind, the content type, and the size when known.
    static func attachmentLine(number: Int, attachment: AgentRuntimeAttachment) -> String {
        var details = [
            attachment.kind.rawValue,
            attachment.contentType?.nilIfBlank
        ].compactMap { $0 }

        if let byteCount = AgentRuntimeAttachmentStore.byteCount(for: attachment) {
            details.append(byteCountText(byteCount))
        }

        let suffix = details.isEmpty ? "" : " (\(details.joined(separator: ", ")))"
        return "  \(number). \(attachment.originalFilename)\(suffix)"
    }

    private static func byteCountText(_ byteCount: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(byteCount),
            countStyle: .file
        )
    }
}
