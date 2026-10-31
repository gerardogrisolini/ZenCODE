//
//  ChatSessionNoticeText.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The plain text of a ``ChatSessionNotice``, character for character what the
/// terminal chat wrote for the same outcome (trailing newline included).
///
/// The terminal's model, thinking, agent, tool, skill, workspace, and
/// `/sessions` helpers delegate here, so each wording lives in one place.
/// Lists are built from the same neutral catalog helpers
/// (``AgentModelCatalogPresentation``) the terminal uses. The wording of the
/// shared slash commands is in `ChatSessionNoticeText+Commands.swift`.
///
/// Two notices carry what the terminal renders with renderers of its own and
/// have a plain fallback instead of a byte-for-byte text:
/// ``ChatSessionNotice/fileChangeSummary(_:includesDiff:)`` (no patches) and
/// ``ChatSessionNotice/fileArtifacts(_:)`` (no diffs). The terminal draws
/// them with its renderers and never writes the fallback.
enum ChatSessionNoticeText {
    /// The text of `notice`, to be written on ``ChatSessionNotice/channel``.
    static func text(for notice: ChatSessionNotice) -> String {
        switch notice {
        case let .operationFailed(description):
            return failureText(description)
        case let .modelSelected(model, thinking):
            return "Selected model: \(modelTitle(model))\(thinkingSuffix(thinking))\n"
        case .modelUnchanged:
            return "Model unchanged.\n"
        case .noCurrentModel:
            return "No current model selected. Use /models to choose a model first.\n"
        case let .thinkingNotSupported(model):
            return "\(modelTitle(model)) does not support configurable thinking.\n"
        case .thinkingUnchanged:
            return "Thinking unchanged.\n"
        case .thinkingTakesNoArguments:
            return failureText("/think does not accept arguments. Use /think to choose a level.")
        case let .selectedAgent(agent):
            return selectedAgentText(agent)
        case let .availableAgents(agents, selected, manifestPath):
            return agentListText(agents, selected: selected, manifestPath: manifestPath)
        case .agentSelectionUsage:
            return agentSelectionUsage
        case let .projectAgentsAssociated(agents, projectName):
            return projectAgentAssociationText(agents, projectName: projectName)
        case let .projectAgentsSaveFailed(description):
            return "ZenCODE: unable to save the project agents: \(description)\n"
        case let .agentSwitched(agent):
            return "Switched to agent: \(agent.displayName). Plan and task graph reset; conversation kept.\n"
        case let .activeTools(summary):
            return activeToolsText(summary)
        case .toolSelectionUsage:
            return toolSelectionUsage
        case let .selectedSkills(skills):
            return selectedSkillsText(skills)
        case .skillSelectionUsage:
            return skillSelectionUsage
        case .skillInstallSourceRequired:
            return "ZenCODE: /skills install requires a GitHub URL or local path.\n"
        case .noPromptSkillsInstalled:
            return "No prompt skills installed by the app.\n"
        case .noSkillsSelectedForUninstall:
            return "No skills selected for uninstall.\n"
        case let .skillsUninstalled(skills):
            let label = skills.count == 1 ? "skill" : "skills"
            return "Uninstalled \(label): \(skills.map(\.title).joined(separator: ", "))\n"
        case let .skillInstallStarted(source):
            return "Installing skill from \(source)...\n"
        case let .skillInstalled(skill):
            return "Installed and selected skill: \(skill.title)\n"
        case let .requiresInteractiveHost(operation):
            return interactiveHostText(operation)
        case let .workspaceAccessDenied(request):
            return "Workspace access was not granted for \(request.workspaceURL.path).\n"
                + "Disabled tools: \(request.toolTitles.joined(separator: ", ")).\n"
        case .sessionStarted:
            return "Started a new session.\n"
        case .noSavedSessions:
            return "No saved sessions for this project.\n"
        case .sessionSelectionUsage:
            return sessionSelectionUsage
        case let .savedSessions(sessions, activeName):
            return savedSessionListText(sessions, activeName: activeName)
        case let .sessionDeleted(name):
            return "Deleted session: \(name).\n"
        case let .savedSessionNotFound(name):
            return "ZenCODE: saved session not found: \(name).\n"
        case .nothingToSave:
            return "ZenCODE: nothing to save yet. Send a prompt first, or use /sessions <session name>.\n"
        case .sessionUnavailableToSave:
            return "ZenCODE: current session is not available to save.\n"
        case let .sessionSaved(name, messageCount):
            return "Saved session: \(name) (\(messageCount) messages).\n"
        case .nothingToCompact:
            return "Nothing to compact yet. The session may be too short or the current model has no context-window limit.\n"
        case let .sessionCompacted(originalTokenCount, tokenCount, keptRecentMessageCount):
            return "Compacted session context from \(tokenCountText(originalTokenCount)) to \(tokenCountText(tokenCount)) estimated tokens, keeping \(keptRecentMessageCount) recent messages.\n"
        case let .sessionLoaded(name, messageCount):
            return "Loaded session: \(name) (\(messageCount) messages).\n"
        case .noActiveSavedSession:
            return "No active saved session. Save first with /sessions save.\n"
        case let .activeSavedSessionNotFound(name):
            return "Active session '\(name)' not found. Try /sessions save first.\n"
        case let .checkpointEntryUnknown(specifier):
            return "Entry '\(specifier)' not found. Use /sessions restore to choose an entry.\n"
        case let .checkpointEntryNotFound(entryID, sessionName):
            return "Checkpoint entry \(entryID) not found in session \(sessionName).\n"
        case let .checkpointRestored(entryID, messageCount):
            return "Restored from checkpoint \(entryID) (\(messageCount) messages on this branch).\n"
        case let .engineCheckpoint(checkpoint):
            return engineCheckpointText(checkpoint)
        case let .help(commandHelp):
            return helpText(commandHelp: commandHelp)
        case let .unknownCommand(line):
            return ChatCommandRegistry.unknownCommandMessage(for: line)
        case let .commandUnavailable(message):
            return message
        case let .subAgentToolsRequired(command):
            return subAgentToolsRequiredText(command: command)
        case let .agentRoleUnavailable(role):
            return AgentProfileStore.roleUnavailableForProjectMessage(role) + "\n"
        case .planMissingGoal:
            return planMissingGoalMessage
        case .planDiscussionBlocksMutation:
            return planDiscussionBlocksMutationMessage
        case .planUnavailableForSaving:
            return planUnavailableForSavingMessage
        case let .planSaved(planID):
            return "Saved plan: \(planID). Use /plan load in a new session to review or revise it.\n"
        case .activePlanAlreadyExists:
            return failureText(
                "an active plan already exists. Use /plan clear before loading a saved plan."
            )
        case .savedPlanUnavailable, .noSavedPlans:
            return savedPlanUnavailableMessage
        case .savedPlansAllCompleted:
            return savedPlansAllTerminalMessage
        case .savedPlanContextNotAdded:
            return failureText("the saved plan could not be added to the current session context.")
        case let .savedPlanLoaded(plan):
            return "Loaded saved plan `\(plan.id)` as an unapproved active plan.\n\n"
                + plan.consolidatedText
                + "\n\nUse /plan approve when it is ready to implement."
        case let .savedPlans(plans):
            return PlanningCommandKernel.savedPlansListMessage(for: plans)
        case .planDeleteUsage:
            return planDeleteUsageMessage
        case let .savedPlanNotFound(availablePlanIDs):
            return PlanningCommandKernel.planDeleteNotFoundMessage(availablePlanIDs: availablePlanIDs)
        case let .savedPlanAmbiguous(matches):
            return PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
        case let .savedPlansDeleted(planIDs, activePlanAffected):
            return PlanningCommandKernel.planDeleteSuccessMessage(
                deletedPlanIDs: planIDs,
                activePlanAffected: activePlanAffected
            )
        case let .planClarificationActive(goal):
            return "Planner clarification is active for: \(goal)\n"
        case .planAwaitingApprovalGoal:
            return "A descriptive Goal is required before plan approval can continue.\n"
        case .noActivePlan:
            return "No active plan.\n"
        case let .planStatus(plan, graph):
            return PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
        case .planUnavailableForApproval:
            return planUnavailableForApprovalMessage
        case .noPendingPlanApproval:
            return failureText("no pending plan approval is available.")
        case .runtimeSessionUnavailable:
            return failureText("the session changed before the command completed.")
        case .planApprovalGoalPrompt:
            return "Before approving this plan, enter a descriptive Goal for the work it represents.\n"
        case .planApproved:
            return "Approved the active plan and activated its task graph. "
                + "Starting implementation now; /review will verify task claims against real files.\n\n"
        case .planDiscussionCleared:
            return "Cleared the unfinished planning discussion.\n"
        case .noPlanToClear:
            return "No active plan or planning discussion to clear.\n"
        case .activePlanCleared:
            return "Cleared the active plan and archived its task graph in this session. "
                + "Saved-plan library copies are unaffected; use /plan delete to remove those.\n"
        case .workflowMissingGoal:
            return workflowMissingGoalMessage
        case .workflowBlockedByPlan:
            return workflowActivePlanMessage
        case let .workflowAlreadyActive(graphID, pendingTaskCount):
            return workflowAlreadyActiveMessage(graphID: graphID, pendingTaskCount: pendingTaskCount)
        case .noChangesToReview:
            return "No tracked session file changes to review.\n"
        case let .taskIDRequired(action):
            return failureText("/tasks \(action) requires a task id.")
        case let .unknownTasksAction(action):
            return failureText(
                "Unknown /tasks action '\(action)'. Use status, show, retry, cancel, or clear."
            )
        case .noTaskGraph:
            return "No task graph for this session.\n"
        case let .taskDetail(view):
            return taskDetailMarkdown(view)
        case let .taskRetried(taskID):
            return "Retried task \(taskID).\n"
        case let .taskCancelled(taskID):
            return "Cancelled task \(taskID).\n"
        case .taskGraphsCleared:
            return "Cleared the session task graphs.\n"
        case .noTrackedFileChanges:
            return "No tracked file changes.\n"
        case let .fileChangeSummary(summary, _):
            return TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
        case .fileChangesReverted:
            return "File changes reverted.\n"
        case let .fileChangesNotUndone(description):
            return "\(description)\n"
        case let .fileChangesUndoFailed(description):
            return failureText("unable to undo file changes: \(description)")
        case .noFileArtifacts:
            return "No file artifacts in the current session.\n"
        case let .fileArtifacts(turns):
            return fileArtifactsFallbackText(turns)
        case .artifactsTakeNoArguments:
            return failureText("/artifacts does not accept arguments.")
        case let .openTargetNotFound(argument):
            return failureText("file not found: \(argument)")
        case .noOpenCandidates:
            return "No files or URLs found in this conversation.\n"
        case .nothingOpened:
            return "Nothing opened.\n"
        case let .opening(target):
            return "Opening \(target.target)\n"
        case .attachmentUsage:
            return attachmentUsage
        case .attachmentDeleteUsage:
            return attachmentDeleteUsage
        case .attachmentSelectionCancelled:
            return "Attachment selection cancelled.\n"
        case let .attachmentsAdded(addedCount, pendingCount):
            let noun = addedCount == 1 ? "attachment" : "attachments"
            return "Added \(addedCount) \(noun). \(pendingCount) pending.\n"
        case .noPendingAttachments:
            return noPendingAttachmentsText
        case let .pendingAttachments(attachments):
            return pendingAttachmentsText(attachments)
        case .pendingAttachmentsRemoved:
            return "Removed all pending attachments.\n"
        case let .attachmentRemoved(filename):
            return "Removed attachment: \(filename)\n"
        case let .invalidAttachmentSelection(argument):
            return failureText("Invalid attachment selection: \(argument).")
        case .unterminatedAttachmentQuote:
            return failureText("Unterminated quoted attachment path.")
        case let .attachmentDirectoryUnreadable(path):
            return "Unable to read attachment directory: \(path).\n"
                + "Grant ZenCODE access in System Settings > Privacy & Security > Files and Folders.\n"
        case let .noAttachableFiles(directoryPath):
            return "No image or video files found in \(directoryPath).\n"
        }
    }

    // MARK: - Interactive hosts

    private static func interactiveHostText(_ operation: ChatInteractiveOperation) -> String {
        switch operation {
        case let .modelSelection(models, selectedModelID):
            return modelListText(models, selectedModelID: selectedModelID)
                + "Model selection requires an interactive terminal.\n"
        case let .thinkingSelection(model, options, selected):
            return thinkingListText(model: model, options: options, selected: selected)
                + "Thinking selection requires an interactive terminal.\n"
        case let .agentSelection(agents, selected, manifestPath):
            return selectedAgentText(selected)
                + agentListText(agents, selected: selected, manifestPath: manifestPath)
                + agentSelectionUsage
        case let .toolSelection(summary):
            return activeToolsText(summary) + toolSelectionUsage
        case let .skillSelection(selected):
            return selectedSkillsText(selected) + skillSelectionUsage
        case .skillUninstall:
            return failureText("/skills uninstall requires an interactive terminal.")
        case let .savedSessionSelection(sessions, activeName),
             let .savedSessionDeletion(sessions, activeName):
            return savedSessionListText(sessions, activeName: activeName) + sessionSelectionUsage
        case let .openSelection(candidates):
            return openCandidateListText(candidates)
                + "Selecting an item to open requires an interactive terminal.\n"
        case .attachmentSelection:
            return failureText("/attach without a path requires an interactive terminal.")
                + attachmentUsage
        }
    }

    // MARK: - Models and thinking

    private static func modelTitle(_ model: AgentSettingsModelManifest) -> String {
        AgentModelCatalogPresentation.modelTitle(for: model)
    }

    /// ` (thinking: <level>)`, or nothing without a level.
    static func thinkingSuffix(_ selection: AgentThinkingSelection?) -> String {
        guard let selection else {
            return ""
        }
        return " (thinking: \(selection.displayTitle))"
    }

    /// The `/models` list, the model `selectedModelID` names flagged.
    static func modelListText(
        _ models: [AgentSettingsModelManifest],
        selectedModelID: String?
    ) -> String {
        var text = "\nAvailable models:\n"
        var offset = 1
        for group in AgentModelCatalogPresentation.groupedByProvider(models) {
            text += "  \(group.title):\n"
            for model in group.models {
                let marker = selectedModelID.map(model.matches) == true ? " *" : ""
                let title = AgentModelCatalogPresentation.modelTitle(for: model, in: group)
                text += "    \(offset). \(title)\(marker)\n"
                offset += 1
            }
        }
        return text + "\n"
    }

    /// The `/think` list of `model`'s levels, `selected` flagged.
    static func thinkingListText(
        model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    ) -> String {
        var text = "\nThinking levels for \(modelTitle(model)):\n"
        for (offset, option) in options.enumerated() {
            let marker = option == selected ? " *" : ""
            text += "  \(offset + 1). \(option.menuTitle)\(marker)\n"
        }
        return text + "\n"
    }

    // MARK: - Agents

    private static let agentSelectionUsage = "Usage: /agents [list|<agent name>|<number>]\n"

    private static func selectedAgentText(_ agent: AgentProfile?) -> String {
        guard let agent else {
            return "Selected agent: unavailable\n"
        }
        return "Selected agent: \(agent.displayName)\n"
    }

    private static func agentListText(
        _ agents: [AgentProfile],
        selected: AgentProfile?,
        manifestPath: String
    ) -> String {
        guard !agents.isEmpty else {
            return "No agents configured in \(manifestPath).\n"
        }

        var text = "\nAvailable agents:\n"
        for (offset, agent) in agents.enumerated() {
            let marker = selected == agent ? " *" : ""
            text += "  \(offset + 1). \(agent.displayName) - \(agentDetail(agent))\(marker)\n"
        }
        return text + "\n"
    }

    /// The detail of an agent in the agent list and the agent menus.
    static func agentDetail(_ agent: AgentProfile) -> String {
        var parts = [agent.role.summary]
        if let modelID = agent.modelID {
            let prefix = agent.modelBindings.count > 1 ? "default model" : "model"
            parts.append("\(prefix): \(modelID)")
        }
        if let thinkingSelection = agent.thinkingSelection {
            parts.append("thinking: \(thinkingSelection.displayTitle)")
        }
        if agent.modelBindings.count > 1 {
            parts.append("bindings: \(agent.modelBindings.count)")
        }
        if !agent.skills.isEmpty {
            parts.append("skills: \(agent.skills.count)")
        }
        return parts.joined(separator: " · ")
    }

    private static func projectAgentAssociationText(
        _ agents: [AgentProfile],
        projectName: String
    ) -> String {
        guard !agents.isEmpty else {
            return "No agent profile is associated with project \(projectName); "
                + "the sub-agents tool cannot delegate until some are associated with /agents.\n"
        }
        return "Project agents for \(projectName): "
            + "\(agents.map(\.displayName).joined(separator: ", ")).\n"
    }

    // MARK: - Tools and skills

    private static let toolSelectionUsage = "Usage: /tools [all|none|tool-name|package-name|tool-number|logs]\n"

    private static let skillSelectionUsage =
        "Usage: /skills [all|none|skill-name|skill-number|install <github-url|local-path>|uninstall|<github-url|local-path>]\n"

    private static func activeToolsText(_ summary: ChatActiveToolsSummary) -> String {
        guard !summary.groups.isEmpty else {
            return "Active tools: none\n"
        }
        let groups = summary.groups.map { "\($0.title) (\($0.toolCount))" }
        return "Active tools: \(groups.joined(separator: ", "))\n"
    }

    private static func selectedSkillsText(_ skills: [PromptSkill]) -> String {
        guard !skills.isEmpty else {
            return "Selected skills: none\n"
        }
        return "Selected skills: \(skills.map(\.title).joined(separator: ", "))\n"
    }

    // MARK: - Sessions

    private static let sessionSelectionUsage = """
        Usage: /sessions                    List and select saved sessions
               /sessions <name>             Save or overwrite a named snapshot
               /sessions save               Save the current session
               /sessions new                Start a new session
               /sessions compact            Compact context
               /sessions delete             Delete a session
               /sessions restore [entry-id] Restore in-place from a checkpoint
                                            (interactive picker when omitted)
        """

    private static func savedSessionListText(
        _ sessions: [ChatSavedSessionSummary],
        activeName: String?
    ) -> String {
        var text = "\nSaved sessions:\n"
        for (offset, session) in sessions.enumerated() {
            let marker = activeName == session.name ? " *" : ""
            text += "  \(offset + 1). \(session.name) - \(savedSessionDetail(session))\(marker)\n"
        }
        return text + "\n"
    }

    /// The detail of a saved session in the saved-session list and menus.
    static func savedSessionDetail(_ session: ChatSavedSessionSummary) -> String {
        var parts: [String] = []
        if let modelID = session.modelID {
            parts.append(modelID)
        }
        parts.append("\(session.messageCount) messages")
        if let usedTokens = session.contextUsedTokens {
            parts.append("ctx \(tokenCountText(usedTokens))")
        }
        parts.append("saved \(timestampText(session.savedAt))")
        return parts.joined(separator: " · ")
    }

    /// A save or update time, short date and short time.
    static func timestampText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// A token count: `950`, `12.3k`, `1.2m`.
    static func tokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }

    // MARK: - Checkpoints

    private static func engineCheckpointText(_ notice: ChatEngineCheckpointNotice) -> String {
        switch notice {
        case .saved:
            return "Saved DS4 KV checkpoint.\n"
        case .skippedImages:
            return "KV checkpoint skipped: session contains images.\n"
        case .skippedNoLiveState:
            return "DS4 KV checkpoint skipped: no live DS4 state for this session.\n"
        case let .saveFailed(description):
            return failureText("DS4 KV checkpoint not saved: \(description)")
        case let .status(message):
            return "\(message)\n"
        case .restored:
            return "Restored DS4 KV checkpoint.\n"
        case .incompatible:
            return "DS4 checkpoint not compatible, the prompt will be re-evaluated.\n"
        case let .restoreFailed(reason):
            return failureText("DS4 KV checkpoint not restored: \(reason)")
        }
    }

    // MARK: - Failures

    /// `ZenCODE: <message>` closed by a newline, the form of every failure line.
    private static func failureText(_ message: String) -> String {
        "ZenCODE: \(message)\n"
    }
}
