//
//  ChatSessionNotice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The channel a text presenter writes a notice on. It carries the tone the
/// terminal gives the message (`writeSystemMessage`, `writeFailureMessage`, or
/// `writeMarkdownMessage`); a channel without that distinction treats the
/// first two alike, and one that does not render Markdown writes the text of
/// a ``markdown`` notice as it is.
enum ChatSessionNoticeChannel: Sendable, Equatable {
    /// An outcome, status, list, or usage line.
    case system
    /// A refusal or an error.
    case failure
    /// Markdown (a table, a plan, a task description) that the terminal
    /// renders with its Markdown formatter.
    case markdown
}

/// The outcome of a session operation, selection command, or shared slash
/// command, with the payload a channel needs to present it.
///
/// A notice states a fact; ``ChatSessionNoticeText/text(for:)`` is the text
/// the terminal writes for it and ``channel`` the tone it writes it in, so a
/// text channel stays identical to the former per-command output. Messages
/// that the terminal printed with several consecutive writes on one channel
/// are one notice. Usage lines that follow a failure on another channel, and
/// the failure lines themselves, are separate notices, in the order the
/// terminal wrote them.
///
/// Two notices carry what the terminal draws with renderers of its own (the
/// width, the colors, or the diff of the terminal): ``fileChangeSummary(_:includesDiff:)``
/// and ``fileArtifacts(_:)``. The terminal intercepts them and draws them
/// with those renderers, the patches and the diffs included. Any other text
/// channel writes ``ChatSessionNoticeText/text(for:)`` for them like for any
/// other notice: a plain text without the patches or the diffs, documented on
/// the case. The task-graph and
/// sub-agent overviews are not notices: they reach the channel through
/// ``ChatSessionPresenter/presentTaskGraphOverview(_:origin:publication:)`` and
/// ``ChatSessionPresenter/presentSubAgentOverview(_:origin:publication:)``.
///
/// The case docs name the former terminal function that wrote the message.
enum ChatSessionNotice: Sendable, Equatable {
    // MARK: - Failures

    /// An operation threw: `ZenCODE: <description>`. Written by the `catch`
    /// blocks of every `/models`, `/think`, `/agents`, `/tools`, `/skills`, and
    /// `/sessions` handler. Failure channel.
    case operationFailed(description: String)

    // MARK: - Models and thinking

    /// A model was selected without asking: the only configured model, or the
    /// one chosen at startup (`handleMissingInitialModelSelectionIfNeeded`).
    case modelSelected(AgentSettingsModelManifest, thinking: AgentThinkingSelection?)
    /// The model menu was cancelled (`selectModelInteractively`).
    case modelUnchanged
    /// `/think` found no current model (`selectThinkingInteractively`).
    case noCurrentModel
    /// The current model has no configurable thinking
    /// (`selectThinkingInteractively`).
    case thinkingNotSupported(model: AgentSettingsModelManifest)
    /// The thinking menu was cancelled (`selectThinkingInteractively`).
    case thinkingUnchanged
    /// `/think` with arguments: the level is chosen from the menu
    /// (`submittedLineAction`). Failure channel.
    case thinkingTakesNoArguments

    // MARK: - Agents

    /// `Selected agent: <name>`, or `unavailable` without one
    /// (`printAgentSelectionStatus`).
    case selectedAgent(AgentProfile?)
    /// The agent list, or the missing-manifest message when `agents` is empty
    /// (`renderAgentList`). `manifestPath` is where the profiles are read from.
    case availableAgents(agents: [AgentProfile], selected: AgentProfile?, manifestPath: String)
    /// The `/agents` usage line (`renderAgentSelectionUsage`).
    case agentSelectionUsage
    /// The agents associated with the project were saved, or none remain
    /// (`renderProjectAgentAssociation`, after `presentProjectAgentMenu`).
    case projectAgentsAssociated(agents: [AgentProfile], projectName: String)
    /// The project's agent association could not be saved
    /// (`presentProjectAgentMenu`). Failure channel.
    case projectAgentsSaveFailed(description: String)
    /// The active agent changed. The conversation is kept; the plan and the
    /// task graph are reset (`applyAgentSelection`).
    case agentSwitched(AgentProfile)

    // MARK: - Tools

    /// The tools currently active (`printToolSelectionStatus`, and the report
    /// of `applyToolSelection`).
    case activeTools(ChatActiveToolsSummary)
    /// The `/tools` usage line (`renderToolSelectionUsage`).
    case toolSelectionUsage

    // MARK: - Skills

    /// `Selected skills: <titles>`, or `none` (`printSkillSelectionStatus`).
    case selectedSkills([PromptSkill])
    /// The `/skills` usage line (`renderSkillSelectionUsage`).
    case skillSelectionUsage
    /// `/skills install` got neither a GitHub URL nor a local path
    /// (`handleSkillsCommand`). Failure channel.
    case skillInstallSourceRequired
    /// No skill is installed to select or uninstall (`handleSkillsCommand`,
    /// `uninstallSkillsInteractively`).
    case noPromptSkillsInstalled
    /// The uninstall menu was confirmed with nothing ticked
    /// (`uninstallSkillsInteractively`).
    case noSkillsSelectedForUninstall
    /// The listed skills were uninstalled (`uninstallSkillsInteractively`).
    case skillsUninstalled([PromptSkill])
    /// A skill install began; `source` is the GitHub URL or the local path
    /// (`installSkill(fromGitHubURL:)`, `installSkill(fromLocalURL:)`).
    case skillInstallStarted(source: String)
    /// The skill was installed and selected (`finishInstalledSkill`).
    case skillInstalled(PromptSkill)

    // MARK: - Interactive hosts and workspace access

    /// The command needs an interactive host that this channel does not have.
    /// The notice carries what the terminal prints without a terminal; see
    /// ``ChatInteractiveOperation`` for the text of each operation.
    case requiresInteractiveHost(ChatInteractiveOperation)
    /// The platform refused the tools access to the workspace, so the listed
    /// tool groups were disabled (`ensureWorkspaceAccessIfNeeded`).
    case workspaceAccessDenied(ChatWorkspaceAccessRequest)

    // MARK: - Sessions

    /// A fresh unsaved session began (`startNewSession`).
    case sessionStarted
    /// The project has no saved session (`handleSavedSessionList`,
    /// `handleSavedSessionDelete`).
    case noSavedSessions
    /// The `/sessions` usage block, which has no trailing newline
    /// (`renderSessionSelectionUsage`).
    case sessionSelectionUsage
    /// The saved sessions of the project, the active one flagged
    /// (`renderSavedSessionList`).
    case savedSessions([ChatSavedSessionSummary], activeName: String?)
    /// A saved session was deleted (`handleSavedSessionDelete`).
    case sessionDeleted(name: String)
    /// The saved session to delete no longer exists
    /// (`handleSavedSessionDelete`). Failure channel.
    case savedSessionNotFound(name: String)
    /// `/sessions save` has no active name and no prompt to derive one from
    /// (`saveActiveSession`). Failure channel.
    case nothingToSave
    /// The runtime holds no snapshot of the active session
    /// (`saveCurrentSession`). Failure channel.
    case sessionUnavailableToSave
    /// The session was saved (`saveCurrentSession`).
    case sessionSaved(name: String, messageCount: Int)
    /// Compaction found nothing to compact (`compactCurrentSession`).
    case nothingToCompact
    /// The context was compacted; token counts are estimates
    /// (`compactCurrentSession`).
    case sessionCompacted(originalTokenCount: Int, tokenCount: Int, keptRecentMessageCount: Int)
    /// A saved session was loaded (`loadSavedSession`).
    case sessionLoaded(name: String, messageCount: Int)

    // MARK: - Checkpoints

    /// `/sessions restore` without a saved session to restore from
    /// (`handleRestoreCommand`). Failure channel.
    case noActiveSavedSession
    /// The active saved session is not in the project's store
    /// (`handleRestoreCommand`). Failure channel.
    case activeSavedSessionNotFound(name: String)
    /// The entry the operator typed is not in the checkpoint tree
    /// (`handleRestoreCommand`). Failure channel.
    case checkpointEntryUnknown(specifier: String)
    /// The resolved entry is not in the saved session's checkpoint tree
    /// (`restoreFromCheckpoint`). Failure channel.
    case checkpointEntryNotFound(entryID: String, sessionName: String)
    /// The session was restored from a checkpoint entry
    /// (`restoreFromCheckpoint`).
    case checkpointRestored(entryID: String, messageCount: Int)
    /// The DS4 KV checkpoint of a saved session (`saveEngineCheckpoint`,
    /// `restoreEngineCheckpoint`).
    case engineCheckpoint(ChatEngineCheckpointNotice)

    // MARK: - Help

    /// `/help` (`renderHelpTextForCurrentAgent`): `commandHelp` holds the help
    /// line of every command the agent can use, in display order; the text
    /// adds the opening line and the live-chat, consent, and editing lines.
    case help(commandHelp: [String])
    /// A line that names no command a shared command runs: a command that
    /// takes no arguments got some (`/undo <arguments>`, the default branch of
    /// `submittedLineAction`). `line` is the submitted line; the text names
    /// its command token (``ChatCommandRegistry/unknownCommandMessage(for:)``).
    /// Failure channel.
    case unknownCommand(line: String)
    /// A command the operator does not see in this session answers with its
    /// own message instead of as an unknown command
    /// (``ChatCommandDescriptor/hiddenMessage``, the terminal's `/feature`
    /// without the Builder agent). `message` is the text, written as is.
    /// Failure channel.
    case commandUnavailable(message: String)

    // MARK: - Commands that need sub-agents

    /// `/plan` or `/review` found the sub-agents tool group off
    /// (`handlePlanCommand`, `handleReviewCommand`). `command` is the typed
    /// command with its slash (`/plan`, `/review`). Failure channel.
    case subAgentToolsRequired(command: String)
    /// No profile visible to the project has the role the command delegates to
    /// (`handlePlanCommand`, `handlePlanBrainstormingReply`,
    /// `handleReviewCommand`). Failure channel.
    case agentRoleUnavailable(AgentProfileRole)

    // MARK: - /plan

    /// `/plan` without a goal (`handlePlanCommand`). Failure channel.
    case planMissingGoal
    /// A Planner clarification or the Goal request of `/plan approve` is open,
    /// so the plan cannot be approved, saved, or loaded
    /// (`handlePlanCommand`). Failure channel.
    case planDiscussionBlocksMutation
    /// `/plan save` found no plan to save (`saveReusablePlan`). Failure channel.
    case planUnavailableForSaving
    /// The plan was saved to the project's library (`saveReusablePlan`).
    case planSaved(planID: String)
    /// `/plan load` while a plan is active (`loadReusablePlan`). Failure channel.
    case activePlanAlreadyExists
    /// The project's library holds no plan, for `/plan load` and
    /// `/plan delete` (`loadReusablePlan`, `deleteSavedPlan`). Failure channel.
    /// ``noSavedPlans`` is the same message for `/plan list`.
    case savedPlanUnavailable
    /// The project's library holds no plan, for `/plan list`
    /// (`listSavedPlans`). The text of ``savedPlanUnavailable``, on the system
    /// channel.
    case noSavedPlans
    /// Every saved plan is completed, so `/plan load` has none to load
    /// (`loadReusablePlan`). Failure channel.
    case savedPlansAllCompleted
    /// The loaded plan could not be added to the session context
    /// (`loadReusablePlan`). Failure channel.
    case savedPlanContextNotAdded
    /// A saved plan was loaded as the unapproved active plan
    /// (`loadReusablePlan`). Markdown channel.
    case savedPlanLoaded(TerminalSessionPlan)
    /// The saved plans of the project, newest first (`listSavedPlans`).
    /// Markdown channel.
    case savedPlans([SavedTaskPlan])
    /// `/plan delete` without a target (`deleteSavedPlan`). Failure channel.
    case planDeleteUsage
    /// No saved plan matches the `/plan delete` target (`deleteSavedPlan`).
    /// Failure channel.
    case savedPlanNotFound(availablePlanIDs: [String])
    /// The `/plan delete` prefix matches several plans (`deleteSavedPlan`).
    /// Failure channel.
    case savedPlanAmbiguous(matches: [String])
    /// Saved plans were deleted (`deleteSavedPlan`). `activePlanAffected` adds
    /// the line that says the session's active plan stays.
    case savedPlansDeleted(planIDs: [String], activePlanAffected: Bool)
    /// `/plan status` while a Planner clarification is open
    /// (`handlePlanCommand`).
    case planClarificationActive(goal: String)
    /// `/plan status` while the Goal request of `/plan approve` is open
    /// (`handlePlanCommand`).
    case planAwaitingApprovalGoal
    /// `/plan status` without a plan or a discussion (`handlePlanCommand`).
    case noActivePlan
    /// `/plan status` with the plan's items and, when the plan has one, its
    /// task graph (`handlePlanCommand`). The plan is the projection of the
    /// graph's progress onto the active plan, which the terminal also keeps as
    /// the active plan. Markdown channel.
    case planStatus(TerminalSessionPlan, graph: TaskGraphSnapshot?)
    /// There is no completed plan to approve (`handlePlanCommand`,
    /// `handlePlanApprovalGoalReply`). Failure channel.
    case planUnavailableForApproval
    /// The Goal of `/plan approve` arrived but the plan it was requested for
    /// is no longer the active plan, and the request stays open. Only the
    /// ACP policy answers so (see ``ChatPlanningCommandPolicy/approval``);
    /// the terminal drops the request and answers
    /// ``planUnavailableForApproval``. Failure channel.
    case noPendingPlanApproval
    /// The runtime session has no generation, so a command that replaces its
    /// history or its task graph stops before changing anything. Only the
    /// ACP policy asks for the generation (see
    /// ``ChatPlanningCommandPolicy``); ACP words it per command. Failure
    /// channel.
    case runtimeSessionUnavailable
    /// `/plan approve` asks for the Goal the plan represents
    /// (`handlePlanCommand`).
    case planApprovalGoalPrompt
    /// The plan was approved and its task graph activated; implementation
    /// starts (`approveActivePlan`).
    case planApproved
    /// `/plan clear` dropped an unfinished discussion and no plan
    /// (`handlePlanCommand`).
    case planDiscussionCleared
    /// `/plan clear` found neither a plan nor a discussion
    /// (`handlePlanCommand`).
    case noPlanToClear
    /// `/plan clear` dropped the active plan and archived its task graph
    /// (`handlePlanCommand`).
    case activePlanCleared

    // MARK: - /goal and /review

    /// `/goal` without a goal (`handleWorkflowCommand`). Failure channel.
    case workflowMissingGoal
    /// `/goal` while a plan or a planning discussion is open
    /// (`handleWorkflowCommand`). Failure channel.
    case workflowBlockedByPlan
    /// `/goal` while a goal workflow graph is still open
    /// (`handleWorkflowCommand`). Failure channel.
    case workflowAlreadyActive(graphID: String, pendingTaskCount: Int)
    /// `/review` found no file change, plan, or task graph to review
    /// (`handleReviewCommand`).
    case noChangesToReview

    // MARK: - /tasks

    /// `/tasks <action>` that needs a task id got none (`TerminalTaskCommandError`,
    /// thrown by `handleTasksCommand`). Failure channel.
    case taskIDRequired(action: String)
    /// `/tasks` with an action it does not know (`TerminalTaskCommandError`,
    /// thrown by `handleTasksCommand`). Failure channel.
    case unknownTasksAction(action: String)
    /// The session has no task graph (`renderCurrentTaskGraph`).
    case noTaskGraph
    /// `/tasks show`: one task with its dependencies, attempts, and evidence
    /// (`taskDetailMarkdown`). Markdown channel.
    case taskDetail(TaskRecordView)
    /// A task was queued again (`handleTasksCommand`).
    case taskRetried(taskID: String)
    /// A task was cancelled (`handleTasksCommand`).
    case taskCancelled(taskID: String)
    /// The task graphs of the session were cleared (`handleTasksCommand`).
    case taskGraphsCleared

    // MARK: - /changes, /undo, and /artifacts

    /// No file change is tracked (`handleChangesCommand`).
    case noTrackedFileChanges
    /// `/changes`: the reconciled file changes of the last turn that changed
    /// files (`writeFileChangeSummary`). `includesDiff` is `/changes diff`.
    ///
    /// The text is the summary the terminal prints, without the patches,
    /// which only the terminal's diff renderer draws (see the type's
    /// documentation).
    case fileChangeSummary(TurnFileChangeSummary, includesDiff: Bool)
    /// `/undo` restored the files of the last summary
    /// (`handleUndoFileChangesCommand`).
    case fileChangesReverted
    /// `/undo` could not apply: nothing to undo, or a file changed since
    /// (`handleUndoFileChangesCommand`, the `TurnFileChangeUndoError` branch).
    /// `description` is the error's own sentence.
    case fileChangesNotUndone(description: String)
    /// `/undo` failed on something else (`handleUndoFileChangesCommand`).
    /// Failure channel.
    case fileChangesUndoFailed(description: String)
    /// The session recorded no file artifact (`handleArtifactsCommand`).
    case noFileArtifacts
    /// `/artifacts`: the artifacts of every turn of the session
    /// (`writeFileArtifacts`, with the history headings). Markdown channel.
    ///
    /// The text lists the turns and the files without the diffs, which only
    /// the terminal's diff renderer draws (see the type's documentation).
    case fileArtifacts([SessionFileArtifactHistory.Turn])
    /// `/artifacts` with arguments (`submittedLineAction`). Failure channel.
    case artifactsTakeNoArguments

    // MARK: - /open

    /// `/open <argument>` names a file that does not exist
    /// (`openDirectArgument`). Failure channel.
    case openTargetNotFound(argument: String)
    /// The conversation mentions no file or URL (`handleOpenCommand`).
    case noOpenCandidates
    /// The selection menu of `/open` was cancelled (`handleOpenCommand`).
    case nothingOpened
    /// The host was asked to open the target (`openTarget`).
    case opening(ChatOpenTarget)

    // MARK: - /attach

    /// The `/attach` usage block (`handleAttachCommand`).
    case attachmentUsage
    /// The `/attach delete` usage line (`deletePendingAttachments`).
    case attachmentDeleteUsage
    /// The attachment picker was cancelled (`handleAttachCommand`).
    case attachmentSelectionCancelled
    /// Attachments were staged for the next prompt (`handleAttachCommand`).
    /// `addedCount` is what this command added, `pendingCount` what waits now.
    case attachmentsAdded(addedCount: Int, pendingCount: Int)
    /// No attachment is staged (`writePendingAttachments`,
    /// `deletePendingAttachments`).
    case noPendingAttachments
    /// The attachments staged for the next prompt, numbered
    /// (`writePendingAttachments`). Empty reads as ``noPendingAttachments``.
    case pendingAttachments([AgentRuntimeAttachment])
    /// `/attach delete all` (`deletePendingAttachments`).
    case pendingAttachmentsRemoved
    /// One staged attachment was removed (`deletePendingAttachments`).
    case attachmentRemoved(filename: String)
    /// `/attach delete` got something that is not an attachment number
    /// (``ChatAttachmentCommandError/invalidDetachArgument(_:)``, raised by
    /// `deletePendingAttachments`). Failure channel.
    case invalidAttachmentSelection(argument: String)
    /// A quote of the `/attach` arguments is not closed
    /// (``ChatAttachmentCommandError/unterminatedQuote``, thrown by
    /// `splitAttachmentCommandArguments`). Failure channel.
    case unterminatedAttachmentQuote
    /// The picker cannot read the folder it is in
    /// (`selectAttachmentURLInteractively`). Raised by the host that owns the
    /// picker, since ``ChatInteractionHost/pickAttachment(startingAt:)``
    /// returns only the chosen file.
    case attachmentDirectoryUnreadable(path: String)
    /// The folder the picker is in holds nothing to choose
    /// (`selectAttachmentURLInteractively`). Raised by the host that owns the
    /// picker.
    case noAttachableFiles(directoryPath: String)

    /// The tone a text channel writes this notice in.
    var channel: ChatSessionNoticeChannel {
        switch self {
        case .operationFailed,
             .unknownCommand,
             .commandUnavailable,
             .thinkingTakesNoArguments,
             .noPendingPlanApproval,
             .runtimeSessionUnavailable,
             .projectAgentsSaveFailed,
             .skillInstallSourceRequired,
             .savedSessionNotFound,
             .nothingToSave,
             .sessionUnavailableToSave,
             .noActiveSavedSession,
             .activeSavedSessionNotFound,
             .checkpointEntryUnknown,
             .checkpointEntryNotFound,
             .subAgentToolsRequired,
             .agentRoleUnavailable,
             .planMissingGoal,
             .planDiscussionBlocksMutation,
             .planUnavailableForSaving,
             .activePlanAlreadyExists,
             .savedPlanUnavailable,
             .savedPlansAllCompleted,
             .savedPlanContextNotAdded,
             .planDeleteUsage,
             .savedPlanNotFound,
             .savedPlanAmbiguous,
             .planUnavailableForApproval,
             .workflowMissingGoal,
             .workflowBlockedByPlan,
             .workflowAlreadyActive,
             .taskIDRequired,
             .unknownTasksAction,
             .fileChangesUndoFailed,
             .artifactsTakeNoArguments,
             .openTargetNotFound,
             .invalidAttachmentSelection,
             .unterminatedAttachmentQuote:
            return .failure
        case .savedPlanLoaded,
             .savedPlans,
             .planStatus,
             .taskDetail,
             .fileArtifacts:
            return .markdown
        case let .requiresInteractiveHost(operation):
            return operation.channel
        case let .engineCheckpoint(notice):
            return notice.channel
        case .modelSelected,
             .modelUnchanged,
             .noCurrentModel,
             .thinkingNotSupported,
             .thinkingUnchanged,
             .selectedAgent,
             .availableAgents,
             .agentSelectionUsage,
             .projectAgentsAssociated,
             .agentSwitched,
             .activeTools,
             .toolSelectionUsage,
             .selectedSkills,
             .skillSelectionUsage,
             .noPromptSkillsInstalled,
             .noSkillsSelectedForUninstall,
             .skillsUninstalled,
             .skillInstallStarted,
             .skillInstalled,
             .workspaceAccessDenied,
             .sessionStarted,
             .noSavedSessions,
             .sessionSelectionUsage,
             .savedSessions,
             .sessionDeleted,
             .sessionSaved,
             .nothingToCompact,
             .sessionCompacted,
             .sessionLoaded,
             .checkpointRestored,
             .help,
             .noSavedPlans,
             .planSaved,
             .savedPlansDeleted,
             .planClarificationActive,
             .planAwaitingApprovalGoal,
             .noActivePlan,
             .planApprovalGoalPrompt,
             .planApproved,
             .planDiscussionCleared,
             .noPlanToClear,
             .activePlanCleared,
             .noChangesToReview,
             .noTaskGraph,
             .taskRetried,
             .taskCancelled,
             .taskGraphsCleared,
             .noTrackedFileChanges,
             .fileChangeSummary,
             .fileChangesReverted,
             .fileChangesNotUndone,
             .noFileArtifacts,
             .noOpenCandidates,
             .nothingOpened,
             .opening,
             .attachmentUsage,
             .attachmentDeleteUsage,
             .attachmentSelectionCancelled,
             .attachmentsAdded,
             .noPendingAttachments,
             .pendingAttachments,
             .pendingAttachmentsRemoved,
             .attachmentRemoved,
             .attachmentDirectoryUnreadable,
             .noAttachableFiles:
            return .system
        }
    }
}

/// An operation that needs an interactive host, with the list the terminal
/// prints when it has no interactive terminal.
///
/// The text of each case is the whole non-interactive output of its command,
/// usage line included, except for ``skillUninstall``, whose refusal is a
/// failure message that the `/skills` usage line (``ChatSessionNotice/skillSelectionUsage``)
/// follows as a separate notice.
enum ChatInteractiveOperation: Sendable, Equatable {
    /// `/models`: the model list, then `Model selection requires an interactive
    /// terminal.` (`selectModelInteractively`).
    case modelSelection(models: [AgentSettingsModelManifest], selectedModelID: String?)
    /// `/think`: the thinking levels of `model`, then `Thinking selection
    /// requires an interactive terminal.` (`selectThinkingInteractively`).
    case thinkingSelection(
        model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    )
    /// `/agents`: the selected agent, the agent list, then the usage line
    /// (`handleAgentsCommand`).
    case agentSelection(agents: [AgentProfile], selected: AgentProfile?, manifestPath: String)
    /// `/tools`: the active tools, then the usage line (`handleToolsCommand`).
    case toolSelection(ChatActiveToolsSummary)
    /// `/skills`: the selected skills, then the usage line
    /// (`handleSkillsCommand`).
    case skillSelection(selected: [PromptSkill])
    /// `/skills uninstall`: `ZenCODE: /skills uninstall requires an interactive
    /// terminal.` on the failure channel (`uninstallSkillsInteractively`).
    case skillUninstall
    /// `/sessions`: the saved sessions, then the usage block
    /// (`handleSavedSessionList`).
    case savedSessionSelection([ChatSavedSessionSummary], activeName: String?)
    /// `/sessions delete`: the saved sessions, then the usage block
    /// (`handleSavedSessionDelete`).
    case savedSessionDeletion([ChatSavedSessionSummary], activeName: String?)
    /// `/open` without an argument: the files and URLs of the conversation,
    /// then `Selecting an item to open requires an interactive terminal.`
    /// (`handleOpenCommand`).
    case openSelection(candidates: [ChatOpenCandidate])
    /// `/attach` without a path: `ZenCODE: /attach without a path requires an
    /// interactive terminal.`, then the usage block, all on the system channel
    /// (`handleAttachCommand`).
    case attachmentSelection

    var channel: ChatSessionNoticeChannel {
        switch self {
        case .skillUninstall:
            return .failure
        case .modelSelection,
             .thinkingSelection,
             .agentSelection,
             .toolSelection,
             .skillSelection,
             .savedSessionSelection,
             .savedSessionDeletion,
             .openSelection,
             .attachmentSelection:
            return .system
        }
    }
}

/// The DS4 KV checkpoint outcomes of saving and loading a session.
enum ChatEngineCheckpointNotice: Sendable, Equatable {
    /// The checkpoint was written next to the saved session.
    case saved
    /// Nothing was written: the session holds images.
    case skippedImages
    /// Nothing was written: the engine holds no live state for the session.
    case skippedNoLiveState
    /// Writing the checkpoint failed; the saved session stays valid. Failure
    /// channel.
    case saveFailed(description: String)
    /// A progress status the backend reported while restoring.
    case status(String)
    /// The checkpoint was loaded.
    case restored
    /// The checkpoint does not match the open model; the prompt is evaluated
    /// again.
    case incompatible
    /// Loading the checkpoint failed; the session still loads. Failure channel.
    case restoreFailed(reason: String)

    var channel: ChatSessionNoticeChannel {
        switch self {
        case .saveFailed, .restoreFailed:
            return .failure
        case .saved, .skippedImages, .skippedNoLiveState, .status, .restored, .incompatible:
            return .system
        }
    }
}
