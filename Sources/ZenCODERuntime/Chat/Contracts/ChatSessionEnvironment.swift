//
//  ChatSessionEnvironment.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// What a channel launched the process with, as the session layer needs it.
///
/// Every channel hands the controller the same immutable launch facts, read
/// once from its ``AgentConfiguration``, so the Chat layer never reaches for
/// environment variables, the current directory, or the terminal to learn them.
public struct ChatSessionEnvironment: Sendable {
    /// Models supplied by the host process (an app). `nil` when the models are
    /// the user's configured catalog.
    public let hostedModels: [AgentSettingsModelManifest]?
    /// Agent profiles supplied by the host process. `nil` when the profiles are
    /// the user's configured agents.
    public let hostedAgentProfiles: [AgentProfile]?
    /// The model the launch explicitly asked for (`--model`, the hosted model).
    public let explicitModelID: String?
    /// The model the launch configuration resolved: the explicit model, the
    /// launch agent's model, or the selected default (for a host, its model).
    /// The last fallback when the session's own selection resolves none.
    public let launchModelID: String?
    /// The agent the launch selected, if any: the requested agent
    /// (``requestedAgentName``), or without one the default developer of the
    /// project of ``launchWorkingDirectory``; `nil` for a launch without
    /// persisted configuration. A session that works in another folder
    /// starts from ``startingAgent(forWorkingDirectory:)`` instead.
    public let launchAgent: AgentProfile?
    /// The working directory the launch resolved (`--working-directory`,
    /// `ZENCODE_AGENT_CWD`, the launch folder, or the hosted working
    /// directory): the folder ``launchAgent`` was selected for.
    public let launchWorkingDirectory: URL
    /// The agent profile name the launch explicitly requested (`--agent`,
    /// `ZENCODE_AGENT`, or the hosted `agentName`), trimmed; `nil` when none
    /// was requested and ``launchAgent`` is the default developer of the
    /// project of ``launchWorkingDirectory``.
    public let requestedAgentName: String?
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    /// Whether the process runs inside a host app rather than a terminal.
    public let appMode: Bool
    /// Raw `--skills` value that seeds the first skill selection.
    public let initialSkillSelection: String?
    /// The session-scoped feature runtime the tool catalog is read from.
    public let featureRuntime: SwiftFeatureRuntime?
    /// The user's home folder: where the attachment picker starts and what a
    /// leading `~` of a workspace path (`/attach`, `/open`) stands for. The
    /// channel that owns a terminal or an account reads it and passes it in;
    /// Chat never reads it from the process. `nil` when the channel has no
    /// home to offer: `~` is then not expanded (the path resolves like any
    /// relative path) and `/attach` offers no picker.
    public let userHomeDirectoryURL: URL?
    /// The Git worktree the launch asked for with `--worktree`, whose
    /// directory is the launch working directory; `nil` without one. A
    /// session whose working directory is that worktree gets its section in
    /// the system prompt.
    public let worktree: AgentWorktree?
    /// Whether a model or thinking choice of a session becomes the user's
    /// default in the settings, with the user's configured catalog (with
    /// hosted models nothing is ever persisted). `false` for a host whose
    /// sessions keep their own choices side by side (a window of an app),
    /// which still start from the persisted defaults. `true` by default.
    public let persistsModelSelections: Bool

    public init(
        configuration: AgentConfiguration,
        featureRuntime: SwiftFeatureRuntime?,
        userHomeDirectoryURL: URL? = nil,
        persistsModelSelections: Bool = true
    ) {
        self.hostedModels = configuration.hostedModels
        self.hostedAgentProfiles = configuration.hostedAgentProfiles
        self.explicitModelID = configuration.modelID
        self.launchModelID = configuration.effectiveModelID
        self.launchAgent = configuration.selectedAgent
        self.launchWorkingDirectory = configuration.workingDirectory
        self.requestedAgentName = configuration.requestedAgentName
        self.maxToolRounds = configuration.maxToolRounds
        self.maxOutputTokens = configuration.maxOutputTokens
        self.appMode = configuration.appMode
        self.initialSkillSelection = configuration.initialSkillSelection
        self.featureRuntime = featureRuntime
        self.userHomeDirectoryURL = userHomeDirectoryURL
        self.worktree = configuration.worktree
        self.persistsModelSelections = persistsModelSelections
    }

    /// The agent a new session working in `directory` starts with, as a
    /// launch in that folder would select it.
    ///
    /// ``launchAgent``, without reading anything, when the launch requested
    /// an agent (``requestedAgentName``), selected none (a launch without
    /// persisted configuration), or `directory` is
    /// ``launchWorkingDirectory``. Otherwise the default developer of the
    /// project of `directory`
    /// (``AgentProfileStore/developerProfile(in:workspaceRootURL:fileManager:)``)
    /// among the hosted profiles (``hostedAgentProfiles``), or the configured
    /// ones without them; a failure to read the profiles or the project's
    /// selection falls back to ``launchAgent``.
    public func startingAgent(forWorkingDirectory directory: URL) -> AgentProfile? {
        guard requestedAgentName == nil, let launchAgent else { return launchAgent }
        guard directory.standardizedFileURL.path != launchWorkingDirectory.standardizedFileURL.path else {
            return launchAgent
        }
        do {
            let agents = try hostedAgentProfiles ?? AgentProfileStore.loadRequired()
            return try AgentProfileStore.developerProfile(in: agents, workspaceRootURL: directory)
        } catch {
            return launchAgent
        }
    }
}
