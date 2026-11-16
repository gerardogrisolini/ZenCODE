//
//  ChatSessionTestSupport+ScriptedRuntime.swift
//  ZenCODE
//
//  The scripted chat runtime test double: a ChatSessionManagementRuntime
//  whose model requests are scripted and whose session management is
//  simulated in memory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Scripted runtime

/// A `ChatSessionManagementRuntime` whose model requests are scripted. Each
/// call to `sendPrompt` runs the next appended script, which drives the event
/// stream and the `onToolWillExecute` hook exactly like the real runner would.
///
/// The session-management half simulates the runner closely enough for the
/// controller to be exercised without a model: it keeps the created sessions
/// (configuration, history, prompt skills) and the task graphs, answers
/// `snapshotSession`, and logs every operation in order.
///
/// - ``calls`` holds the operations that act on the runtime (create, restore,
///   update, reset, rebuild, shutdown, compact, preload, skills, checkpoints,
///   task graphs, saved plans, tasks, and the adoption and deletion of
///   resumable task graphs). Nothing in it means the controller left
///   the runtime alone.
/// - ``queries`` holds the read-only lookups (snapshots, task graphs, tool
///   descriptors), which the controller makes to compute what it presents;
///   ``resumableTaskGraphCheckpointReadCount`` counts the listings of the
///   resumable task graphs.
actor ScriptedChatRuntime: ChatSessionManagementRuntime {
    nonisolated let taskOrchestrator: SessionTaskOrchestrator

    private let defaultToolAuthorization: AgentToolAuthorizationHandler?
    private var scripts: [Script] = []
    private var plannerSnapshots: [DirectSubAgentRuntime.AgentSnapshot] = []
    private(set) var prompts: [String] = []
    private(set) var attachmentCounts: [Int] = []
    private(set) var turnInstructions: [String?] = []
    private(set) var authorizationResults: [Bool] = []
    private(set) var replacedHistories: [[AgentRuntimeMessage]] = []

    // Session management.
    private(set) var calls: [ManagementCall] = []
    private(set) var queries: [Query] = []
    private var sessionConfigurations: [String: AgentCoreSessionConfiguration] = [:]
    private var sessionHistories: [String: [AgentRuntimeMessage]] = [:]
    private var sessionPromptSkills: [String: [PromptSkill]] = [:]
    private var preloadedModelID: String?
    /// What ``activeToolDescriptors(sessionID:)`` answers; none by default.
    private var activeDescriptors: [DirectToolDescriptor] = []
    private var compactionResult: AgentRuntimeSessionCompactionResult?
    private var engineSaveOutcome: AgentEngineCheckpointSaveOutcome = .notApplicable
    private var engineSaveError: Error?
    private var engineRestoreOutcome: AgentEngineCheckpointRestoreOutcome = .notApplicable
    private var engineRestoreEvents: [DirectAgentEvent] = []
    private var updateSessionOptionsError: Error?
    private var taskGraphReadHook: (@Sendable (Int) async -> Void)?
    private var taskGraphReadCount = 0
    private var taskGraphActivationHook: (@Sendable (String) async -> Void)?
    /// How many times the controller listed the resumable task graphs.
    private(set) var resumableTaskGraphCheckpointReadCount = 0
    /// The error the next adoptions of a resumable task graph throw, one
    /// per adoption, before reaching the orchestrator.
    private var adoptResumableTaskGraphErrors: [Error] = []
    /// How many times the controller read the sub-agent snapshots.
    private(set) var subAgentSnapshotReadCount = 0
    private var subAgentSnapshotReadHook: (@Sendable (Int) async -> Void)?

    /// `defaultToolAuthorization` plays the role of the runner's
    /// `defaultToolAuthorizationHandler`: it answers calls whose turn request
    /// did not bring its own handler. `taskGraphStore` persists the task
    /// graphs and the saved-plan library; without one they live in memory
    /// and the library is always empty.
    init(
        defaultToolAuthorization: AgentToolAuthorizationHandler? = nil,
        taskGraphStore: SessionTaskGraphStore? = nil
    ) {
        self.defaultToolAuthorization = defaultToolAuthorization
        self.taskOrchestrator = SessionTaskOrchestrator(store: taskGraphStore)
    }

    func append(_ script: @escaping Script) {
        scripts.append(script)
    }

    func setPlannerSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        plannerSnapshots = snapshots
    }

    /// The sub-agent snapshots the runtime reports from now on: the same
    /// list the planner reads (see ``setPlannerSnapshots(_:)``).
    func setSubAgentSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        plannerSnapshots = snapshots
    }

    /// Runs `hook` during each sub-agent snapshot read from now on, before the
    /// read returns, with the number of reads (1 for the first). A test holds
    /// a read in flight there, or checks what happened before it.
    func setSubAgentSnapshotReadHook(_ hook: (@Sendable (Int) async -> Void)?) {
        subAgentSnapshotReadHook = hook
    }

    func recordAuthorization(_ approved: Bool) {
        authorizationResults.append(approved)
    }

    // MARK: Scripting the management half

    /// Forgets the logged operations and lookups, keeping the sessions.
    func clearCalls() {
        calls = []
        queries = []
    }

    func setPreloadedModelID(_ modelID: String?) {
        preloadedModelID = modelID
    }

    func setActiveToolDescriptors(_ descriptors: [DirectToolDescriptor]) {
        activeDescriptors = descriptors
    }

    func setCompactionResult(_ result: AgentRuntimeSessionCompactionResult?) {
        compactionResult = result
    }

    func setEngineSaveOutcome(_ outcome: AgentEngineCheckpointSaveOutcome) {
        engineSaveOutcome = outcome
        engineSaveError = nil
    }

    func setEngineSaveError(_ error: Error?) {
        engineSaveError = error
    }

    func setEngineRestore(
        outcome: AgentEngineCheckpointRestoreOutcome,
        events: [DirectAgentEvent] = []
    ) {
        engineRestoreOutcome = outcome
        engineRestoreEvents = events
    }

    /// Runs `hook` with the graph's ID after each task-graph activation from
    /// now on, before the activation returns. A test lands a cancellation
    /// there, between two steps of an approval.
    func setTaskGraphActivationHook(_ hook: (@Sendable (String) async -> Void)?) {
        taskGraphActivationHook = hook
    }

    /// Makes the next adoption of a resumable task graph throw `error`
    /// without changing any checkpoint.
    func failNextAdoptResumableTaskGraph(_ error: Error) {
        adoptResumableTaskGraphErrors.append(error)
    }

    /// Gives the runtime session a conversation of its own, as if turns had
    /// run in it.
    func setSessionHistory(_ history: [AgentRuntimeMessage], sessionID: String) {
        sessionHistories[sessionID] = history
    }

    /// The prompt skills the runtime session currently holds.
    func promptSkills(for sessionID: String) -> [PromptSkill] {
        sessionPromptSkills[sessionID] ?? []
    }

    /// The configuration the runtime session was last created or updated with.
    func configuration(for sessionID: String) -> AgentCoreSessionConfiguration? {
        sessionConfigurations[sessionID]
    }

    var sessionIDs: Set<String> {
        Set(sessionConfigurations.keys)
    }

    // MARK: ChatSessionRuntime

    func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler?,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders: [AgentToolProvider],
        turnInstruction: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let index = prompts.count
        prompts.append(prompt)
        attachmentCounts.append(attachments.count)
        turnInstructions.append(turnInstruction)
        guard index < scripts.count else {
            throw ScriptError.missingScript(index: index)
        }
        let script = scripts[index]
        return try await script(Call(
            index: index,
            authorizeTool: authorizeTool ?? defaultToolAuthorization,
            onToolWillExecute: onToolWillExecute,
            onEvent: onEvent,
            runtime: self
        ))
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        subAgentSnapshotReadCount += 1
        let snapshots = plannerSnapshots
        await subAgentSnapshotReadHook?(subAgentSnapshotReadCount)
        return snapshots
    }

    func closeSubAgent(id: String) async -> Bool {
        true
    }

    func taskGraphSnapshot(sessionID: String, graphID: String?) async throws -> TaskGraphSnapshot? {
        queries.append(.taskGraphSnapshot(sessionID))
        let snapshot = try await taskOrchestrator.graphSnapshot(sessionID: sessionID, graphID: graphID)
        if let taskGraphReadHook {
            taskGraphReadCount += 1
            await taskGraphReadHook(taskGraphReadCount)
        }
        return snapshot
    }

    func removeTaskGraph(id: String, sessionID: String) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.removeGraph(id: id, sessionID: sessionID)
    }

    func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        queries.append(.snapshotSession(sessionID))
        guard let configuration = sessionConfigurations[sessionID] else {
            return nil
        }
        return AgentRuntimeSessionSnapshot(
            sessionID: configuration.sessionID,
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectory.path,
            systemPrompt: configuration.systemPrompt,
            dynamicContext: configuration.dynamicContext,
            cacheKey: configuration.cacheKey,
            history: sessionHistories[sessionID] ?? configuration.history,
            allowedToolNames: configuration.allowedToolNames,
            thinkingSelection: configuration.thinkingSelection,
            preserveThinking: configuration.preserveThinking
        )
    }

    func currentSessionGeneration(for sessionID: String) -> AgentCoreSessionRunner.SessionGeneration? {
        AgentCoreSessionRunner.SessionGeneration(rawValue: 1)
    }

    func replaceSessionHistory(
        id sessionID: String,
        history: [AgentRuntimeMessage],
        expectedSessionGeneration: AgentCoreSessionRunner.SessionGeneration
    ) async -> Bool {
        replacedHistories.append(history)
        return true
    }

    // MARK: ChatSessionManagementRuntime

    func createSession(configuration: AgentCoreSessionConfiguration) async throws {
        calls.append(.createSession(SessionDigest(configuration)))
        sessionConfigurations[configuration.sessionID] = configuration
        sessionHistories[configuration.sessionID] = configuration.history
    }

    func restoreSession(configuration: AgentCoreSessionConfiguration) async throws {
        calls.append(.restoreSession(SessionDigest(configuration)))
        sessionConfigurations[configuration.sessionID] = configuration
        sessionHistories[configuration.sessionID] = configuration.history
    }

    func updateSessionOptions(configuration: AgentCoreSessionConfiguration) async throws {
        calls.append(.updateSessionOptions(SessionDigest(configuration)))
        if let updateSessionOptionsError {
            throw updateSessionOptionsError
        }
        // The conversation of a running session stays as it is.
        sessionConfigurations[configuration.sessionID] = configuration
    }

    func resetSession(id sessionID: String?) async {
        calls.append(.resetSession(sessionID))
        guard let sessionID else {
            sessionConfigurations = [:]
            sessionHistories = [:]
            sessionPromptSkills = [:]
            return
        }
        sessionConfigurations[sessionID] = nil
        sessionHistories[sessionID] = nil
        sessionPromptSkills[sessionID] = nil
        try? await taskOrchestrator.discardSession(id: sessionID)
    }

    func rebuildSession(id sessionID: String) async {
        calls.append(.rebuildSession(sessionID))
        // Task graphs survive; the prompt-skill provider does not.
        sessionConfigurations[sessionID] = nil
        sessionHistories[sessionID] = nil
        sessionPromptSkills[sessionID] = nil
    }

    func shutdownBackendKeepingExternalTools() async {
        calls.append(.shutdownBackendKeepingExternalTools)
        sessionConfigurations = [:]
        sessionHistories = [:]
        sessionPromptSkills = [:]
    }

    func compactSession(
        id sessionID: String,
        force: Bool,
        maxTokensOverride: Int?
    ) async throws -> AgentRuntimeSessionCompactionResult? {
        calls.append(.compactSession(
            sessionID: sessionID,
            force: force,
            maxTokensOverride: maxTokensOverride
        ))
        return compactionResult
    }

    func preloadModel(
        configuration: AgentCoreSessionConfiguration,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        calls.append(.preloadModel(SessionDigest(configuration)))
        let modelID = preloadedModelID ?? configuration.modelID ?? "scripted-model"
        await onEvent(.modelLoaded(modelID))
        return modelID
    }

    func updatePromptSkillSelection(_ skills: [PromptSkill], sessionID: String) async {
        calls.append(.updatePromptSkillSelection(skillNames: skills.map(\.canonicalName), sessionID: sessionID))
        sessionPromptSkills[sessionID] = skills
    }

    func saveEngineCheckpoint(
        sessionID: String,
        to url: URL
    ) async throws -> AgentEngineCheckpointSaveOutcome {
        calls.append(.saveEngineCheckpoint(sessionID: sessionID, fileName: url.lastPathComponent))
        if let engineSaveError {
            throw engineSaveError
        }
        if engineSaveOutcome == .saved {
            // The engine writes the KV cache next to the saved session.
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("kv-cache".utf8).write(to: url)
        }
        return engineSaveOutcome
    }

    func restoreEngineCheckpoint(
        sessionID: String,
        from url: URL,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> AgentEngineCheckpointRestoreOutcome {
        calls.append(.restoreEngineCheckpoint(sessionID: sessionID, fileName: url.lastPathComponent))
        for event in engineRestoreEvents {
            await onEvent(event)
        }
        return engineRestoreOutcome
    }

    func restoreTaskGraph(
        _ snapshot: TaskGraphSnapshot,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        calls.append(.restoreTaskGraph(graphID: snapshot.id, sessionID: sessionID))
        return try await taskOrchestrator.restoreTaskGraph(snapshot, sessionID: sessionID)
    }

    func clearTaskGraphs(sessionID: String) async throws {
        calls.append(.clearTaskGraphs(sessionID: sessionID))
        try await taskOrchestrator.clearTaskGraphs(sessionID: sessionID)
    }

    func savedTaskPlans(workingDirectory: URL) async -> [SavedTaskPlan] {
        await taskOrchestrator.savedTaskPlans(workingDirectory: workingDirectory)
    }

    func deleteSavedTaskPlans(
        planIDs: [String],
        workingDirectory: URL
    ) async throws -> [String] {
        calls.append(.deleteSavedTaskPlans(planIDs: planIDs))
        return try await taskOrchestrator.deleteSavedTaskPlans(
            planIDs: planIDs,
            workingDirectory: workingDirectory
        )
    }

    func activateTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        calls.append(.activateTaskGraph(graphID: graphID, sessionID: sessionID))
        let snapshot = try await taskOrchestrator.activateGraph(id: graphID, sessionID: sessionID)
        await taskGraphActivationHook?(graphID)
        return snapshot
    }

    func archiveTaskGraph(
        id graphID: String,
        sessionID: String
    ) async throws -> TaskGraphSnapshot {
        calls.append(.archiveTaskGraph(graphID: graphID, sessionID: sessionID))
        return try await taskOrchestrator.archiveGraph(id: graphID, sessionID: sessionID)
    }

    func retryTask(
        id taskID: String,
        sessionID: String,
        expectedRevision: Int?
    ) async throws -> TaskRecordView {
        calls.append(.retryTask(
            taskID: taskID,
            sessionID: sessionID,
            expectedRevision: expectedRevision
        ))
        return try await taskOrchestrator.retryTask(
            sessionID: sessionID,
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    /// Cancels the task and, like the runner, closes the sub-agent that was
    /// working on it.
    func cancelTask(
        id taskID: String,
        sessionID: String,
        reason: String?
    ) async throws -> TaskCancellation {
        calls.append(.cancelTask(taskID: taskID, sessionID: sessionID, reason: reason))
        let cancellation = try await taskOrchestrator.cancelTask(
            sessionID: sessionID,
            taskID: taskID,
            reason: reason
        )
        if let agentID = cancellation.agentID {
            _ = await closeSubAgent(id: agentID)
        }
        return cancellation
    }

    /// Puts a task graph in the session without logging an operation, as if
    /// the model had planned it during a turn.
    func seedTaskGraph(_ snapshot: TaskGraphSnapshot, sessionID: String) async throws {
        try await taskOrchestrator.restoreTaskGraph(snapshot, sessionID: sessionID)
    }

    func resumableTaskGraphCheckpoints(workingDirectory: URL) async -> [ResumableTaskGraph] {
        resumableTaskGraphCheckpointReadCount += 1
        return await taskOrchestrator.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        )
    }

    func removeResumableTaskGraphs(
        _ graphs: [ResumableTaskGraph],
        workingDirectory: URL
    ) async throws {
        calls.append(.removeResumableTaskGraphs(ids: graphs.map(\.id)))
        try await taskOrchestrator.removeResumableTaskGraphs(
            graphs,
            workingDirectory: workingDirectory
        )
    }

    func adoptResumableTaskGraph(
        _ graph: ResumableTaskGraph,
        intoSessionID sessionID: String,
        workingDirectory: URL
    ) async throws -> TaskGraphSnapshot {
        calls.append(.adoptResumableTaskGraph(id: graph.id, intoSessionID: sessionID))
        if !adoptResumableTaskGraphErrors.isEmpty {
            throw adoptResumableTaskGraphErrors.removeFirst()
        }
        return try await taskOrchestrator.adoptResumableTaskGraph(
            graph,
            intoSessionID: sessionID,
            workingDirectory: workingDirectory
        )
    }

    func activeToolDescriptors(sessionID: String) async -> [DirectToolDescriptor] {
        queries.append(.activeToolDescriptors(sessionID))
        return activeDescriptors
    }

    func knownMCPToolDescriptors(
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL?,
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        queries.append(.knownMCPToolDescriptors)
        return []
    }
}
