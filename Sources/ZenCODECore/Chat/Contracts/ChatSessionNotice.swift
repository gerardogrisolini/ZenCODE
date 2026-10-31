//
//  ChatSessionNotice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// The channel a text presenter writes a notice on. It carries the tone the
/// terminal gives the message (`writeSystemMessage` or `writeFailureMessage`);
/// a channel without that distinction treats both alike.
enum ChatSessionNoticeChannel: Sendable, Equatable {
    /// An outcome, status, list, or usage line.
    case system
    /// A refusal or an error.
    case failure
}

/// The outcome of a session operation or selection command, with the payload a
/// channel needs to present it.
///
/// A notice states a fact; ``ChatSessionNoticeText/text(for:)`` is the text
/// the terminal writes for it and ``channel`` the tone it writes it in, so a
/// text channel stays identical to the former per-command output. Messages
/// that the terminal printed with several consecutive writes on one channel
/// are one notice. Usage lines that follow a failure on another channel, and
/// the failure lines themselves, are separate notices, in the order the
/// terminal wrote them.
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

    /// The tone a text channel writes this notice in.
    var channel: ChatSessionNoticeChannel {
        switch self {
        case .operationFailed,
             .projectAgentsSaveFailed,
             .skillInstallSourceRequired,
             .savedSessionNotFound,
             .nothingToSave,
             .sessionUnavailableToSave,
             .noActiveSavedSession,
             .activeSavedSessionNotFound,
             .checkpointEntryUnknown,
             .checkpointEntryNotFound:
            return .failure
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
             .checkpointRestored:
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
             .savedSessionDeletion:
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
