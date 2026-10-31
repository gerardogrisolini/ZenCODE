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
        case submittedCommand(String)
        /// A task-graph publication was reserved; `nil` when the presenter
        /// does not reserve.
        case taskGraphReservation(ChatOverviewPublication?)
        case taskGraphOverview(
            ChatTaskGraphOverview?,
            origin: ChatOverviewOrigin,
            publication: ChatOverviewPublication?
        )
        /// A sub-agent publication was reserved; `nil` when the presenter
        /// does not reserve. Recorded only while
        /// ``recordsSubAgentOverviews`` is on.
        case subAgentReservation(ChatOverviewPublication?)
        /// A sub-agent overview, reduced to what tests compare (the
        /// snapshots are not `Equatable`). Recorded only while
        /// ``recordsSubAgentOverviews`` is on.
        case subAgentOverview(
            agentIDs: [String],
            signature: String,
            currentBatchID: String?,
            origin: ChatOverviewOrigin,
            publication: ChatOverviewPublication?
        )
    }

    private(set) var events: [Event] = []
    private var submittedCommandHook: (@Sendable (String) async -> Void)?
    /// Whether ``reserveTaskGraphOverviewPublication()`` hands out
    /// reservations (revisions 1, 2, 3, ...) or reserves nothing (`nil`).
    private(set) var reservesTaskGraphPublications = true
    private var lastReservedRevision = 0
    /// Whether the presenter takes part in the sub-agent overview. Off by
    /// default, like a channel that does not present it: it reserves nothing
    /// and records nothing, so the event sequences of the other suites stay
    /// as they are.
    private(set) var recordsSubAgentOverviews = false
    /// While ``recordsSubAgentOverviews`` is on, whether
    /// ``reserveSubAgentOverviewPublication()`` hands out reservations
    /// (revisions 1, 2, 3, ..., counted apart from the task-graph ones) or
    /// reserves nothing (`nil`).
    private(set) var reservesSubAgentPublications = true
    private var lastReservedSubAgentRevision = 0
    private var eventWaiters: [(
        predicate: @Sendable ([Event]) -> Bool,
        continuation: CheckedContinuation<Void, Never>
    )] = []

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

    func setReservesTaskGraphPublications(_ reserves: Bool) {
        reservesTaskGraphPublications = reserves
    }

    func setRecordsSubAgentOverviews(_ records: Bool) {
        recordsSubAgentOverviews = records
    }

    func setReservesSubAgentPublications(_ reserves: Bool) {
        reservesSubAgentPublications = reserves
    }

    /// The sub-agent reservations taken so far, in order.
    var subAgentReservations: [ChatOverviewPublication?] {
        events.compactMap { event in
            if case let .subAgentReservation(publication) = event {
                return .some(publication)
            }
            return nil
        }
    }

    /// The sub-agent overviews presented so far, in order.
    var subAgentOverviews: [(
        agentIDs: [String],
        signature: String,
        currentBatchID: String?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    )] {
        events.compactMap { event in
            if case let .subAgentOverview(agentIDs, signature, currentBatchID, origin, publication) = event {
                return (agentIDs, signature, currentBatchID, origin, publication)
            }
            return nil
        }
    }

    /// Returns once `count` sub-agent overviews have been presented.
    func waitForSubAgentOverviews(_ count: Int) async {
        await waitUntil { events in
            events.count { if case .subAgentOverview = $0 { true } else { false } } >= count
        }
    }

    /// The task-graph reservations taken so far, in order.
    var taskGraphReservations: [ChatOverviewPublication?] {
        events.compactMap { event in
            if case let .taskGraphReservation(publication) = event {
                return .some(publication)
            }
            return nil
        }
    }

    /// The task-graph overviews presented so far, in order.
    var taskGraphOverviews: [(
        overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    )] {
        events.compactMap { event in
            if case let .taskGraphOverview(overview, origin, publication) = event {
                return (overview, origin, publication)
            }
            return nil
        }
    }

    /// Returns once the recorded events satisfy `predicate`, without polling:
    /// every appended event re-checks the waiters.
    func waitUntil(_ predicate: @escaping @Sendable ([Event]) -> Bool) async {
        guard !predicate(events) else { return }
        await withCheckedContinuation { continuation in
            eventWaiters.append((predicate, continuation))
        }
    }

    /// Returns once `count` task-graph reservations have been taken.
    func waitForTaskGraphReservations(_ count: Int) async {
        await waitUntil { events in
            events.count { if case .taskGraphReservation = $0 { true } else { false } } >= count
        }
    }

    /// Returns once `count` task-graph overviews have been presented.
    func waitForTaskGraphOverviews(_ count: Int) async {
        await waitUntil { events in
            events.count { if case .taskGraphOverview = $0 { true } else { false } } >= count
        }
    }

    private func record(_ event: Event) {
        events.append(event)
        let ready = eventWaiters.filter { $0.predicate(events) }
        eventWaiters.removeAll { $0.predicate(events) }
        for waiter in ready {
            waiter.continuation.resume()
        }
    }

    func turnWillStart(_ request: ChatTurnRequest) async {
        record(.turnWillStart(prompt: request.prompt))
    }

    func presentStatus(_ status: String) async {
        record(.status(status))
    }

    func presentDiagnostic(_ diagnostic: String) async {
        record(.diagnostic(diagnostic))
    }

    func presentThought(_ thought: String) async {
        record(.thought(thought))
    }

    func presentAssistantContent(_ content: String) async {
        record(.content(content))
    }

    func presentModelLoaded(_ modelID: String) async {
        record(.modelLoaded(modelID))
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        record(.toolStarted(toolCall.id))
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        record(.toolCompleted(toolCall.id))
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        record(.toolSettled(toolCall.id))
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        record(.liveArtifacts(
            agentID: agentID,
            paths: turns.flatMap { $0.artifacts.map(\.displayPath) }
        ))
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        record(.sealedArtifacts(paths: turn.artifacts.map(\.displayPath)))
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        record(.fileChangeSummary(fileCount: summary.fileCount))
    }

    func modelTurnDidReturn() async {
        record(.modelTurnDidReturn)
    }

    func turnWillContinueAutomatically() async {
        record(.continueAutomatically)
    }

    func turnWillFinish() async {
        record(.turnWillFinish)
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        record(.workflowNotice(notice))
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        record(.turnEnded(outcome.status))
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        record(.sessionNotice(notice))
    }

    func presentSessionStateChanged(_ state: ChatSessionState) async {
        record(.sessionStateChanged(state))
    }

    func presentSubmittedCommand(_ line: String) async {
        record(.submittedCommand(line))
        await submittedCommandHook?(line)
    }

    /// Runs `hook` after each echo of a submitted command from now on. A test
    /// lands a cancellation there, between two steps of a command.
    func setSubmittedCommandHook(_ hook: (@Sendable (String) async -> Void)?) {
        submittedCommandHook = hook
    }

    func reserveTaskGraphOverviewPublication() async -> ChatOverviewPublication? {
        var publication: ChatOverviewPublication?
        if reservesTaskGraphPublications {
            lastReservedRevision += 1
            publication = ChatOverviewPublication(revision: lastReservedRevision)
        }
        record(.taskGraphReservation(publication))
        return publication
    }

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        record(.taskGraphOverview(overview, origin: origin, publication: publication))
    }

    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        guard recordsSubAgentOverviews else { return nil }
        var publication: ChatOverviewPublication?
        if reservesSubAgentPublications {
            lastReservedSubAgentRevision += 1
            publication = ChatOverviewPublication(revision: lastReservedSubAgentRevision)
        }
        record(.subAgentReservation(publication))
        return publication
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard recordsSubAgentOverviews else { return }
        record(.subAgentOverview(
            agentIDs: overview.snapshots.map(\.id),
            signature: overview.signature,
            currentBatchID: overview.currentBatchID,
            origin: origin,
            publication: publication
        ))
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
        case openExternal(ChatOpenTarget)
        case pickAttachment(startingAt: URL)
    }

    /// The failure a scripted `openExternal` throws.
    struct OpenExternalFailure: LocalizedError {
        let message: String

        var errorDescription: String? { message }
    }

    nonisolated let capabilities: ChatChannelCapabilities
    private var decisions: [ChatConsentDecision?]
    private var oneAnswers: [String?]
    private var manyAnswers: [Set<String>?]
    private var focusedAnswers: [ChatFocusedChoice?]
    private var lineAnswers: [String?]
    private var workspaceAnswers: [Bool]
    private var attachmentAnswers: [URL?] = []
    private var openFailures: [String] = []
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

    /// Queues the file the next attachment picker returns (`nil` cancels).
    func answerPickAttachment(_ answer: URL?) {
        attachmentAnswers.append(answer)
    }

    /// Makes the next `openExternal` throw `message`; without one it opens.
    func failNextOpenExternal(_ message: String) {
        openFailures.append(message)
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

    /// Records the target and opens nothing: a test never launches a file or
    /// a URL.
    func openExternal(_ target: ChatOpenTarget) async throws {
        interactions.append(.openExternal(target))
        if !openFailures.isEmpty {
            throw OpenExternalFailure(message: openFailures.removeFirst())
        }
    }

    func pickAttachment(startingAt directory: URL) async -> URL? {
        interactions.append(.pickAttachment(startingAt: directory))
        return attachmentAnswers.isEmpty ? nil : attachmentAnswers.removeFirst()
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
///   task graphs, saved plans, tasks). Nothing in it means the controller left
///   the runtime alone.
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
        case deleteSavedTaskPlans(planIDs: [String])
        case activateTaskGraph(graphID: String, sessionID: String)
        case archiveTaskGraph(graphID: String, sessionID: String)
        case retryTask(taskID: String, sessionID: String, expectedRevision: Int?)
        case cancelTask(taskID: String, sessionID: String, reason: String?)

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
            case .deleteSavedTaskPlans: "deleteSavedTaskPlans"
            case .activateTaskGraph: "activateTaskGraph"
            case .archiveTaskGraph: "archiveTaskGraph"
            case .retryTask: "retryTask"
            case .cancelTask: "cancelTask"
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
    private var compactionResult: AgentRuntimeSessionCompactionResult?
    private var engineSaveOutcome: AgentEngineCheckpointSaveOutcome = .notApplicable
    private var engineSaveError: Error?
    private var engineRestoreOutcome: AgentEngineCheckpointRestoreOutcome = .notApplicable
    private var engineRestoreEvents: [DirectAgentEvent] = []
    private var updateSessionOptionsError: Error?
    private var taskGraphReadHook: (@Sendable (Int) async -> Void)?
    private var taskGraphReadCount = 0
    private var taskGraphActivationHook: (@Sendable (String) async -> Void)?
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

    /// Runs `hook` after each task-graph read from now on, before the read
    /// returns its snapshot, with the number of reads since the hook was set
    /// (1 for the first). A test changes the graph there to land a change
    /// between two reads of the controller.
    func setTaskGraphReadHook(_ hook: (@Sendable (Int) async -> Void)?) {
        taskGraphReadHook = hook
        taskGraphReadCount = 0
    }

    /// Runs `hook` with the graph's ID after each task-graph activation from
    /// now on, before the activation returns. A test lands a cancellation
    /// there, between two steps of an approval.
    func setTaskGraphActivationHook(_ hook: (@Sendable (String) async -> Void)?) {
        taskGraphActivationHook = hook
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

// MARK: - Recording channel hooks

/// Channel hooks that record every command step the controller asks of the
/// channel, in order, each with the runtime operations the controller had
/// asked for when it ran: a test reads where a step falls among the runtime
/// steps, and that it precedes the closing notices the command returns.
@ChatSessionActor
final class RecordingChannelHooks: ChatSessionChannelHooks {
    private let runtime: ScriptedChatRuntime
    /// The steps so far: the hook, then the runtime operations at that point.
    private(set) var steps: [String] = []
    /// What ``commandContextWindow()`` answers.
    var contextWindow: DirectAgentContextWindowStatus?
    /// What ``newSessionID()`` answers.
    var mintedSessionID: String?

    init(runtime: ScriptedChatRuntime) {
        self.runtime = runtime
    }

    private func record(_ step: String) async {
        let calls = await runtime.calls.map(\.name)
        steps.append("\(step) after \(calls)")
    }

    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {
        await record("selectionDidApply(\(change), \(command))")
    }

    func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        await record("commandContextWindow")
        return contextWindow
    }

    func newSessionID() -> String? {
        steps.append("newSessionID")
        return mintedSessionID
    }

    func sessionWillStartNew() async {
        await record("sessionWillStartNew")
    }

    func sessionDidStartNew() async {
        await record("sessionDidStartNew")
    }

    func sessionDidCompact(contextWindow: DirectAgentContextWindowStatus) async {
        let tokens = contextWindow.usedTokens.map(String.init) ?? "-"
        let maximum = contextWindow.maxTokens.map(String.init) ?? "-"
        await record("sessionDidCompact(\(tokens)/\(maximum))")
    }

    func sessionWillCreate(reason: ChatSessionRecreationReason) async {
        await record("sessionWillCreate(\(reason))")
    }

    func sessionDidCreate(reason: ChatSessionRecreationReason) async {
        await record("sessionDidCreate(\(reason))")
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
/// reads or writes the real application state. `persistsTaskGraphs` gives the
/// runtime a task-graph store in that support directory, which the saved-plan
/// library needs. `userHomeDirectoryURL` is the home the environment hands
/// the controller (none by default).
func withChatHarness(
    catalog: ChatTestCatalog = .hosted(),
    hostCapabilities: ChatChannelCapabilities = [],
    hostDecisions: [ChatConsentDecision?] = [],
    retainsTranscript: Bool = true,
    persistsTaskGraphs: Bool = false,
    userHomeDirectoryURL: URL? = nil,
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
        let runtime = ScriptedChatRuntime(
            taskGraphStore: persistsTaskGraphs
                ? SessionTaskGraphStore(supportDirectoryURL: support)
                : nil
        )
        let presenter = RecordingChatPresenter()
        let controller = ChatSessionController(
            sessionID: "chat-session-\(UUID().uuidString.lowercased())",
            managementRuntime: runtime,
            environment: ChatSessionEnvironment(
                configuration: configuration,
                featureRuntime: nil,
                userHomeDirectoryURL: userHomeDirectoryURL
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

// MARK: - Sleep gate

/// A `sleep` seam under the test's control (the task-graph observer's
/// debounce, the interval of the sub-agent overview refresh): a wait lasts
/// until the test opens the gate, and a cancelled wait ends at once by
/// throwing, as `Task.sleep` does.
actor DebounceGate {
    private var waiting: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var cancelledBeforeWaiting: Set<UUID> = []
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    /// The duration of every wait started so far, in order.
    private(set) var durations: [Duration] = []

    /// The `sleep` the seam runs.
    nonisolated func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await wait(id: id, duration: duration)
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Returns once `count` waits have started.
    func waitForEntries(_ count: Int) async {
        guard durations.count < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    /// Ends every wait in progress.
    func open() {
        let continuations = Array(waiting.values)
        waiting.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func wait(id: UUID, duration: Duration) async throws {
        durations.append(duration)
        let entered = durations.count
        let ready = entryWaiters.filter { $0.count <= entered }
        entryWaiters.removeAll { $0.count <= entered }
        for waiter in ready {
            waiter.continuation.resume()
        }
        if cancelledBeforeWaiting.remove(id) != nil || Task.isCancelled {
            throw CancellationError()
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting[id] = continuation
        }
    }

    private func cancel(id: UUID) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancelledBeforeWaiting.insert(id)
        }
    }
}
