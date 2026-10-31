//
//  ChatSessionTestSupport.swift
//  ZenCODE
//
//  Test doubles shared by the Chat-layer suites: a scripted session runtime
//  (turns and session management, with an ordered call log), a presenter that
//  records every event, a scripted interaction host with configurable
//  capabilities and a queue of answers, and the harness that wires them to a
//  `ChatSessionController` inside a throwaway support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// MARK: - Recording presenter

actor RecordingChatPresenter: ChatSessionPresenter {
    enum Event: Equatable, Sendable {
        case turnWillStart(prompt: String)
        case status(String)
        case diagnostic(String)
        case thought(String)
        case content(String)
        case modelLoaded(String)
        case toolStarted(String)
        case toolCompleted(String)
        case toolSettled(String)
        case liveArtifacts(agentID: String?, paths: [String])
        case sealedArtifacts(paths: [String])
        case fileChangeSummary(fileCount: Int)
        case modelTurnDidReturn
        case continueAutomatically
        case turnWillFinish
        case workflowNotice(ChatWorkflowNotice)
        case turnEnded(DirectAgentTurnOutcome.Status)
        case sessionNotice(ChatSessionNotice)
        case sessionStateChanged(ChatSessionState)
    }

    private(set) var events: [Event] = []

    /// The session notices presented so far, in order.
    var notices: [ChatSessionNotice] {
        events.compactMap { event in
            if case let .sessionNotice(notice) = event {
                return notice
            }
            return nil
        }
    }

    /// The complete session states presented so far, in order.
    var states: [ChatSessionState] {
        events.compactMap { event in
            if case let .sessionStateChanged(state) = event {
                return state
            }
            return nil
        }
    }

    func clear() {
        events = []
    }

    func turnWillStart(_ request: ChatTurnRequest) async {
        events.append(.turnWillStart(prompt: request.prompt))
    }

    func presentStatus(_ status: String) async {
        events.append(.status(status))
    }

    func presentDiagnostic(_ diagnostic: String) async {
        events.append(.diagnostic(diagnostic))
    }

    func presentThought(_ thought: String) async {
        events.append(.thought(thought))
    }

    func presentAssistantContent(_ content: String) async {
        events.append(.content(content))
    }

    func presentModelLoaded(_ modelID: String) async {
        events.append(.modelLoaded(modelID))
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        events.append(.toolStarted(toolCall.id))
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        events.append(.toolCompleted(toolCall.id))
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        events.append(.toolSettled(toolCall.id))
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        events.append(.liveArtifacts(
            agentID: agentID,
            paths: turns.flatMap { $0.artifacts.map(\.displayPath) }
        ))
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        events.append(.sealedArtifacts(paths: turn.artifacts.map(\.displayPath)))
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        events.append(.fileChangeSummary(fileCount: summary.fileCount))
    }

    func modelTurnDidReturn() async {
        events.append(.modelTurnDidReturn)
    }

    func turnWillContinueAutomatically() async {
        events.append(.continueAutomatically)
    }

    func turnWillFinish() async {
        events.append(.turnWillFinish)
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        events.append(.workflowNotice(notice))
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        events.append(.turnEnded(outcome.status))
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        events.append(.sessionNotice(notice))
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        events.append(.sessionStateChanged(state))
    }
}

// MARK: - Scripted interaction host

/// A `ChatInteractionHost` with the capabilities the test gives it. Every
/// interaction is recorded in order; the answers come from queues, and an
/// empty queue means the operator cancelled (`nil`), except for the workspace
/// access, which a host without a folder gate grants.
actor ScriptedChatInteractionHost: ChatInteractionHost {
    /// One interaction the controller asked of the host.
    enum Interaction: Equatable, Sendable {
        case chooseOne(title: String, items: [ChatChoiceItem], selectedID: String?)
        case chooseMany(title: String, items: [ChatChoiceItem], selectedIDs: Set<String>)
        case chooseManyWithFocus(
            title: String,
            items: [ChatChoiceItem],
            selectedIDs: Set<String>,
            focusedID: String?,
            toggleLabel: String,
            confirmLabel: String
        )
        case readLine(prompt: String)
        case requestWorkspaceAccess(ChatWorkspaceAccessRequest)
    }

    nonisolated let capabilities: ChatChannelCapabilities
    private var decisions: [ChatConsentDecision?]
    private var oneAnswers: [String?]
    private var manyAnswers: [Set<String>?]
    private var focusedAnswers: [ChatFocusedChoice?]
    private var lineAnswers: [String?]
    private var workspaceAnswers: [Bool]
    private(set) var requests: [AgentToolAuthorizationRequest] = []
    private(set) var interactions: [Interaction] = []

    init(
        capabilities: ChatChannelCapabilities,
        decisions: [ChatConsentDecision?] = [],
        chooseOne: [String?] = [],
        chooseMany: [Set<String>?] = [],
        chooseManyWithFocus: [ChatFocusedChoice?] = [],
        readLine: [String?] = [],
        workspaceAccess: [Bool] = []
    ) {
        self.capabilities = capabilities
        self.decisions = decisions
        self.oneAnswers = chooseOne
        self.manyAnswers = chooseMany
        self.focusedAnswers = chooseManyWithFocus
        self.lineAnswers = readLine
        self.workspaceAnswers = workspaceAccess
    }

    var requestCount: Int { requests.count }

    func answerChooseOne(_ answer: String?) {
        oneAnswers.append(answer)
    }

    func answerChooseMany(_ answer: Set<String>?) {
        manyAnswers.append(answer)
    }

    func answerChooseManyWithFocus(_ answer: ChatFocusedChoice?) {
        focusedAnswers.append(answer)
    }

    func answerReadLine(_ answer: String?) {
        lineAnswers.append(answer)
    }

    func answerWorkspaceAccess(_ granted: Bool) {
        workspaceAnswers.append(granted)
    }

    func clearInteractions() {
        interactions = []
    }

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        requests.append(request)
        return decisions.isEmpty ? nil : decisions.removeFirst()
    }

    func chooseOne(
        title: String,
        items: [ChatChoiceItem],
        selectedID: String?
    ) async -> String? {
        interactions.append(.chooseOne(title: title, items: items, selectedID: selectedID))
        return oneAnswers.isEmpty ? nil : oneAnswers.removeFirst()
    }

    func chooseMany(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>
    ) async -> Set<String>? {
        interactions.append(.chooseMany(title: title, items: items, selectedIDs: selectedIDs))
        return manyAnswers.isEmpty ? nil : manyAnswers.removeFirst()
    }

    func chooseManyWithFocus(
        title: String,
        items: [ChatChoiceItem],
        selectedIDs: Set<String>,
        focusedID: String?,
        toggleLabel: String,
        confirmLabel: String
    ) async -> ChatFocusedChoice? {
        interactions.append(.chooseManyWithFocus(
            title: title,
            items: items,
            selectedIDs: selectedIDs,
            focusedID: focusedID,
            toggleLabel: toggleLabel,
            confirmLabel: confirmLabel
        ))
        return focusedAnswers.isEmpty ? nil : focusedAnswers.removeFirst()
    }

    func readLine(prompt: String) async -> String? {
        interactions.append(.readLine(prompt: prompt))
        return lineAnswers.isEmpty ? nil : lineAnswers.removeFirst()
    }

    func requestWorkspaceAccess(_ request: ChatWorkspaceAccessRequest) async -> Bool {
        interactions.append(.requestWorkspaceAccess(request))
        return workspaceAnswers.isEmpty ? true : workspaceAnswers.removeFirst()
    }
}

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
///   task graphs). Nothing in it means the controller left the runtime alone.
/// - ``queries`` holds the read-only lookups (snapshots, task graphs, tool
///   descriptors), which the controller makes to compute what it presents.
actor ScriptedChatRuntime: ChatSessionManagementRuntime {
    struct Call: Sendable {
        let index: Int
        let authorizeTool: AgentToolAuthorizationHandler?
        let onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?
        let onEvent: @Sendable (DirectAgentEvent) async -> Void
        let runtime: ScriptedChatRuntime
    }

    typealias Script = @Sendable (Call) async throws -> DirectAgentResponse

    enum ScriptError: Error {
        case missingScript(index: Int)
    }

    /// What a session-creating call received, reduced to what tests compare.
    struct SessionDigest: Equatable, Sendable {
        let sessionID: String
        let modelID: String?
        let agentID: String?
        let allowedToolNames: Set<String>?
        let thinkingSelection: AgentThinkingSelection?
        let historyContents: [String]

        init(_ configuration: AgentCoreSessionConfiguration) {
            sessionID = configuration.sessionID
            modelID = configuration.modelID
            agentID = configuration.agentID
            allowedToolNames = configuration.allowedToolNames
            thinkingSelection = configuration.thinkingSelection
            historyContents = configuration.history.map(\.content)
        }
    }

    /// An operation the controller asked of the runtime.
    enum ManagementCall: Equatable, Sendable {
        case createSession(SessionDigest)
        case restoreSession(SessionDigest)
        case updateSessionOptions(SessionDigest)
        case resetSession(String?)
        case rebuildSession(String)
        case shutdownBackendKeepingExternalTools
        case compactSession(sessionID: String, force: Bool, maxTokensOverride: Int?)
        case preloadModel(SessionDigest)
        case updatePromptSkillSelection(skillIDs: [String], sessionID: String)
        case saveEngineCheckpoint(sessionID: String, fileName: String)
        case restoreEngineCheckpoint(sessionID: String, fileName: String)
        case restoreTaskGraph(graphID: String, sessionID: String)
        case clearTaskGraphs(sessionID: String)

        /// The operation's name, for asserting the order of a sequence.
        var name: String {
            switch self {
            case .createSession: "createSession"
            case .restoreSession: "restoreSession"
            case .updateSessionOptions: "updateSessionOptions"
            case .resetSession: "resetSession"
            case .rebuildSession: "rebuildSession"
            case .shutdownBackendKeepingExternalTools: "shutdownBackendKeepingExternalTools"
            case .compactSession: "compactSession"
            case .preloadModel: "preloadModel"
            case .updatePromptSkillSelection: "updatePromptSkillSelection"
            case .saveEngineCheckpoint: "saveEngineCheckpoint"
            case .restoreEngineCheckpoint: "restoreEngineCheckpoint"
            case .restoreTaskGraph: "restoreTaskGraph"
            case .clearTaskGraphs: "clearTaskGraphs"
            }
        }

        /// The session configuration the operation carried, if it carried one.
        var digest: SessionDigest? {
            switch self {
            case let .createSession(digest),
                 let .restoreSession(digest),
                 let .updateSessionOptions(digest),
                 let .preloadModel(digest):
                digest
            default:
                nil
            }
        }
    }

    /// A read-only lookup the controller made.
    enum Query: Equatable, Sendable {
        case snapshotSession(String)
        case taskGraphSnapshot(String)
        case activeToolDescriptors(String)
        case knownMCPToolDescriptors
    }

    struct ScriptedFailure: Error, LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated let taskOrchestrator = SessionTaskOrchestrator()

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
    private var compactionResult: AgentRuntimeSessionCompactionResult?
    private var engineSaveOutcome: AgentEngineCheckpointSaveOutcome = .notApplicable
    private var engineSaveError: Error?
    private var engineRestoreOutcome: AgentEngineCheckpointRestoreOutcome = .notApplicable
    private var engineRestoreEvents: [DirectAgentEvent] = []
    private var updateSessionOptionsError: Error?

    /// `defaultToolAuthorization` plays the role of the runner's
    /// `defaultToolAuthorizationHandler`: it answers calls whose turn request
    /// did not bring its own handler.
    init(defaultToolAuthorization: AgentToolAuthorizationHandler? = nil) {
        self.defaultToolAuthorization = defaultToolAuthorization
    }

    func append(_ script: @escaping Script) {
        scripts.append(script)
    }

    func setPlannerSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        plannerSnapshots = snapshots
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

    func setUpdateSessionOptionsError(_ error: Error?) {
        updateSessionOptionsError = error
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
        plannerSnapshots
    }

    func closeSubAgent(id: String) async -> Bool {
        true
    }

    func taskGraphSnapshot(sessionID: String, graphID: String?) async throws -> TaskGraphSnapshot? {
        queries.append(.taskGraphSnapshot(sessionID))
        return try await taskOrchestrator.graphSnapshot(sessionID: sessionID, graphID: graphID)
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
        calls.append(.updatePromptSkillSelection(skillIDs: skills.map(\.id), sessionID: sessionID))
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

    /// Puts a task graph in the session without logging an operation, as if
    /// the model had planned it during a turn.
    func seedTaskGraph(_ snapshot: TaskGraphSnapshot, sessionID: String) async throws {
        try await taskOrchestrator.restoreTaskGraph(snapshot, sessionID: sessionID)
    }

    func activeToolDescriptors(sessionID: String) async -> [DirectToolDescriptor] {
        queries.append(.activeToolDescriptors(sessionID))
        return []
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

// MARK: - Fixtures

/// Models, agents, and files the Chat-layer suites share.
enum ChatTestFixtures {
    /// Offers no configurable thinking.
    static let alpha = AgentSettingsModelManifest(
        id: "alpha-model",
        kind: .remoteAPI,
        title: "Alpha Model",
        modelID: "test/alpha"
    )

    /// Offers `.low` (default) and `.high`.
    static let beta = AgentSettingsModelManifest(
        id: "beta-model",
        kind: .remoteAPI,
        title: "Beta Model",
        modelID: "test/beta",
        thinkingOptions: [.low, .high],
        defaultThinkingSelection: .low
    )

    /// The two hosted models above, the first one at launch.
    static let hostedModels = [alpha, beta]

    /// A model of the user's configured catalog. A configured remote model
    /// needs a provider, otherwise `settings.json` drops it.
    static func configuredModel(
        _ id: String,
        title: String,
        thinkingOptions: [AgentThinkingSelection] = [],
        defaultThinkingSelection: AgentThinkingSelection? = nil
    ) -> AgentSettingsModelManifest {
        let modelID = "local/\(id)"
        return AgentSettingsModelManifest(
            id: id,
            kind: .remoteAPI,
            title: title,
            modelID: modelID,
            provider: AgentRemoteProvider(
                name: "remote-server",
                baseURL: "http://127.0.0.1",
                modelID: modelID
            ),
            thinkingOptions: thinkingOptions.isEmpty ? nil : thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection
        )
    }

    static let configuredAlpha = configuredModel("configured-alpha", title: "Configured Alpha")
    static let configuredBeta = configuredModel(
        "configured-beta",
        title: "Configured Beta",
        thinkingOptions: [.low, .high],
        defaultThinkingSelection: .low
    )

    static let developer = ProjectAgentSelectionTestSupport.developer
    static let reviewer = ProjectAgentSelectionTestSupport.reviewer
    static let reporter = ProjectAgentSelectionTestSupport.reporter

    static func message(_ role: AgentRuntimeMessage.Role, _ content: String) -> AgentRuntimeMessage {
        AgentRuntimeMessage(role: role, content: content)
    }

    /// A two-message conversation.
    static let conversation = [
        AgentRuntimeMessage(role: .user, content: "Where is the bug?"),
        AgentRuntimeMessage(role: .assistant, content: "In the parser."),
    ]

    /// A four-message conversation.
    static let longConversation = conversation + [
        AgentRuntimeMessage(role: .user, content: "Can you fix it?"),
        AgentRuntimeMessage(role: .assistant, content: "Fixed."),
    ]

    /// Writes `<root>/<name>/SKILL.md` and returns the skill folder.
    @discardableResult
    static func writeSkill(
        named name: String,
        in root: URL,
        description: String? = nil
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try """
        ---
        name: \(name)
        description: \(description ?? "The \(name) test skill.")
        ---

        # \(name)

        Follow the \(name) instructions.
        """
        .write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        return directory
    }

    /// A task graph with one coordinator task.
    static func taskGraph(id: String) -> TaskGraphSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return TaskGraphSnapshot(
            id: id,
            source: .plan(planID: "plan-\(id)"),
            state: .active,
            revision: 1,
            tasks: [
                TaskRecord(
                    id: "\(id)-1",
                    title: "Read the parser",
                    order: 1,
                    createdAt: date,
                    updatedAt: date
                ),
            ],
            createdAt: date,
            updatedAt: date
        )
    }
}

// MARK: - Harness

/// How the harness's environment resolves its models.
enum ChatTestCatalog: Sendable {
    /// The host process supplies the models and the agents: nothing is ever
    /// written to the user's settings.
    case hosted(
        models: [AgentSettingsModelManifest] = ChatTestFixtures.hostedModels,
        agents: [AgentProfile] = [ChatTestFixtures.developer, ChatTestFixtures.reviewer]
    )
    /// The models are the user's configured catalog, read from (and written
    /// to) `settings.json` in the support directory.
    case configured(
        models: [AgentSettingsModelManifest],
        selectedModelID: String? = nil
    )
}

/// A `ChatSessionController` over a scripted runtime, host, and presenter,
/// inside a support directory and a working directory named by UUIDs.
struct ChatManagementHarness: Sendable {
    let support: URL
    let workspace: URL
    let runtime: ScriptedChatRuntime
    let host: ScriptedChatInteractionHost
    let presenter: RecordingChatPresenter
    let controller: ChatSessionController

    var settingsURL: URL {
        support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
    }

    var skillsRoot: URL {
        support.appendingPathComponent("skills", isDirectory: true)
    }

    /// Forgets everything recorded so far, so a test asserts only on what its
    /// operation did.
    func clearRecords() async {
        await runtime.clearCalls()
        await presenter.clear()
        await host.clearInteractions()
    }

    /// Creates the runtime session for the controller's current selection
    /// with `conversation` as its history, then clears the records.
    @ChatSessionActor
    func startSession(
        conversation: [AgentRuntimeMessage] = [],
        transcript: [AgentRuntimeMessage]? = nil
    ) async throws {
        controller.history = conversation
        controller.transcript = transcript ?? conversation
        try await controller.createSessionWithSelectedSkills(discoverExternalTools: false)
        await clearRecords()
    }
}

extension ChatManagementHarness {
    /// The names of the operations the runtime was asked for, in order.
    func callNames() async -> [String] {
        await runtime.calls.map(\.name)
    }

    /// Installs the skills `names` in the support directory, as the app
    /// catalog holds them, and returns them as the controller discovers them.
    @ChatSessionActor
    func installSkills(_ names: String...) throws -> [PromptSkill] {
        for name in names {
            try ChatTestFixtures.writeSkill(named: name, in: skillsRoot)
        }
        controller.availableSkillsCache = nil
        let skills = controller.availableSkills()
        return try names.map { name in
            try #require(skills.first { $0.canonicalName == name })
        }
    }
}

/// Runs `body` with a throwaway support directory and working directory (both
/// named by a UUID) and a task-local support-directory override, so no test
/// reads or writes the real application state.
func withChatHarness(
    catalog: ChatTestCatalog = .hosted(),
    hostCapabilities: ChatChannelCapabilities = [],
    hostDecisions: [ChatConsentDecision?] = [],
    retainsTranscript: Bool = true,
    _ body: @escaping @Sendable @ChatSessionActor (ChatManagementHarness) async throws -> Void
) async throws {
    let temporary = FileManager.default.temporaryDirectory
    let support = temporary.appendingPathComponent(
        "zencode-chat-support-\(UUID().uuidString)",
        isDirectory: true
    )
    let workspace = temporary.appendingPathComponent(
        "zencode-chat-workspace-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: support)
        try? FileManager.default.removeItem(at: workspace)
    }

    try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
        // Everything the layer reads or writes goes to the UUID-named directory.
        #expect(
            AppStorageDirectory.appSupportDirectoryURL().standardizedFileURL.path
                == support.standardizedFileURL.path
        )
        let configuration: AgentConfiguration
        switch catalog {
        case let .hosted(models, agents):
            configuration = try AgentConfiguration(
                hostedModelID: models.first?.id ?? "scripted-model",
                availableAgents: agents,
                availableModels: models,
                workingDirectory: workspace
            )
            #expect(configuration.hostedModels != nil)
        case let .configured(models, selectedModelID):
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: models, selectedModelID: selectedModelID),
                to: support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
            )
            // `--model` is always passed, so an ambient `ZENCODE_AGENT_MODEL`
            // cannot stand in for the explicit model (an empty value means none).
            configuration = try AgentConfiguration.withoutPersistedConfiguration(
                arguments: [
                    "zen",
                    "--model", "",
                    "--working-directory", workspace.path,
                ]
            )
            #expect(configuration.hostedModels == nil)
        }

        let host = ScriptedChatInteractionHost(
            capabilities: hostCapabilities,
            decisions: hostDecisions
        )
        let runtime = ScriptedChatRuntime()
        let presenter = RecordingChatPresenter()
        let controller = ChatSessionController(
            sessionID: "chat-session-\(UUID().uuidString.lowercased())",
            managementRuntime: runtime,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: nil
            ),
            workingDirectory: configuration.workingDirectory,
            presenter: presenter,
            host: host,
            authorizer: ChatToolConsentAuthorizer(host: host),
            retainsTranscript: retainsTranscript
        )
        try await body(
            ChatManagementHarness(
                support: support,
                workspace: configuration.workingDirectory,
                runtime: runtime,
                host: host,
                presenter: presenter,
                controller: controller
            )
        )
    }
}


/// The error `operation` throws, or `nil` when it completes.
@ChatSessionActor
func capturedError<T>(_ operation: () async throws -> T) async -> Error? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}
