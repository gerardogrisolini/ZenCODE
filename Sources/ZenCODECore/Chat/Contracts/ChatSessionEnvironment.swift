//
//  ChatSessionEnvironment.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// What a channel launched the process with, as the session layer needs it.
///
/// Every channel hands the controller the same immutable launch facts, read
/// once from its ``AgentConfiguration``, so the Chat layer never reaches for
/// environment variables, the current directory, or the terminal to learn them.
struct ChatSessionEnvironment: Sendable {
    /// Models supplied by the host process (an app). `nil` when the models are
    /// the user's configured catalog.
    let hostedModels: [AgentSettingsModelManifest]?
    /// Agent profiles supplied by the host process. `nil` when the profiles are
    /// the user's configured agents.
    let hostedAgentProfiles: [AgentProfile]?
    /// The model the launch explicitly asked for (`--model`, the hosted model).
    let explicitModelID: String?
    /// The model the launch configuration resolved: the explicit model, the
    /// launch agent's model, or the selected default (for a host, its model).
    /// The last fallback when the session's own selection resolves none.
    let launchModelID: String?
    /// The agent the launch selected, if any.
    let launchAgent: AgentProfile?
    let maxToolRounds: Int
    let maxOutputTokens: Int?
    /// Whether the process runs inside a host app rather than a terminal.
    let appMode: Bool
    /// Raw `--skills` value that seeds the first skill selection.
    let initialSkillSelection: String?
    /// The session-scoped feature runtime the tool catalog is read from.
    let featureRuntime: SwiftFeatureRuntime?

    /// Whether model and thinking choices become the persisted defaults.
    /// A host that supplies its own models owns that choice, so nothing is
    /// written to the user's settings.
    var persistsSelections: Bool {
        hostedModels == nil
    }

    init(
        configuration: AgentConfiguration,
        featureRuntime: SwiftFeatureRuntime?
    ) {
        self.hostedModels = configuration.hostedModels
        self.hostedAgentProfiles = configuration.hostedAgentProfiles
        self.explicitModelID = configuration.modelID
        self.launchModelID = configuration.effectiveModelID
        self.launchAgent = configuration.selectedAgent
        self.maxToolRounds = configuration.maxToolRounds
        self.maxOutputTokens = configuration.maxOutputTokens
        self.appMode = configuration.appMode
        self.initialSkillSelection = configuration.initialSkillSelection
        self.featureRuntime = featureRuntime
    }
}
