//
//  ChatSessionManagementRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The runtime operations behind the session and selection commands.
///
/// ``ChatSessionRuntime`` is deliberately narrow, enough to run turns. A
/// controller that also creates, resets, compacts, and saves sessions, switches
/// the model, and rebuilds the tool and skill selection drives this extension
/// of it. `AgentCoreSessionRunner` implements it with the signatures it already
/// has, so the requirements spell out the parameters its defaults fill in.
protocol ChatSessionManagementRuntime: ChatSessionRuntime {
    // MARK: Sessions

    func createSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws

    /// Recreates a saved session's runtime state from its configuration.
    func restoreSession(
        configuration: AgentCoreSessionConfiguration
    ) async throws

    func updateSessionOptions(
        configuration: AgentCoreSessionConfiguration
    ) async throws

    /// Discards the session, its task graphs included. `nil` discards every
    /// session of the runtime.
    func resetSession(id sessionID: String?) async

    /// Rebuilds the session's transient state while keeping its task graphs.
    func rebuildSession(id sessionID: String) async

    /// Shuts down the model backend and every session, keeping the connected
    /// external MCP servers alive.
    func shutdownBackendKeepingExternalTools() async

    func compactSession(
        id sessionID: String,
        force: Bool,
        maxTokensOverride: Int?
    ) async throws -> AgentRuntimeSessionCompactionResult?

    // MARK: Model and skills

    /// Loads the configuration's model and returns its ID.
    func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String

    func updatePromptSkillSelection(
        _ skills: [PromptSkill],
        sessionID: String
    ) async

    // MARK: Checkpoints and task graphs

    func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome

    /// Call it after ``restoreSession(configuration:)``, so the backend session
    /// already holds the restored messages the checkpoint is matched against.
    func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome

    @discardableResult
    func restoreTaskGraph(
        _ snapshot: TaskGraphSnapshot,
        sessionID: String
    ) async throws -> TaskGraphSnapshot

    func clearTaskGraphs(sessionID: String) async throws

    /// The plans in the project's saved-plan library.
    func savedTaskPlans(
        workingDirectory: URL
    ) async -> [SavedTaskPlan]

    /// Removes the plans from the project's saved-plan library and returns the
    /// IDs that were found and removed.
    @discardableResult
    func deleteSavedTaskPlans(
        planIDs: [String],
        workingDirectory: URL
    ) async throws -> [String]

    @discardableResult
    func activateTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot

    @discardableResult
    func archiveTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot

    @discardableResult
    func retryTask(
        id taskID: String,
        sessionID: String,
        expectedRevision: Int?
    ) async throws -> TaskRecordView

    /// Cancels the task and closes the sub-agent that was working on it.
    @discardableResult
    func cancelTask(
        id taskID: String,
        sessionID: String,
        reason: String?
    ) async throws -> TaskCancellation

    // MARK: Tools

    func activeToolDescriptors(
        sessionID: String
    ) async -> [DirectToolDescriptor]

    /// The descriptors of the MCP tools known so far, discovered or not yet
    /// connected, optionally restricted to `allowedToolNames` and scoped to a
    /// workspace and a session.
    func knownMCPToolDescriptors(
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL?,
        sessionID: String?
    ) async -> [DirectToolDescriptor]
}

extension AgentCoreSessionRunner: ChatSessionManagementRuntime {}
