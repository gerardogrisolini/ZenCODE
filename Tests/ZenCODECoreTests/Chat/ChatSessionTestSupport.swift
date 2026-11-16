//
//  ChatSessionTestSupport.swift
//  ZenCODE
//
//  Test doubles shared by the Chat-layer suites: a scripted session runtime
//  (turns and session management, with an ordered call log), a presenter that
//  records every event (also as an observer, optionally into a log several
//  presenters share), a scripted interaction host with configurable
//  capabilities and a queue of answers, and the harness that wires them to a
//  `ChatSessionController` inside a throwaway support directory.
//

import Foundation
import Synchronization
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
        case toolPreview(DirectAgentToolCallPreview)
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
    /// The name this presenter's entries carry in ``log``.
    nonisolated let name: String
    /// Where the presenter also writes every event it records, next to the
    /// other presenters that share it; `nil` by default, which records the
    /// events only in ``events``.
    nonisolated let log: ChatPresentationLog?
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

    init(name: String = "primary", log: ChatPresentationLog? = nil) {
        self.name = name
        self.log = log
    }

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

    func setRecordsSubAgentOverviews(_ records: Bool) {
        recordsSubAgentOverviews = records
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
        log?.append(event, presenter: name)
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

    func presentToolCallPreview(_ preview: DirectAgentToolCallPreview) async {
        record(.toolPreview(preview))
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

/// A recording presenter also observes a controller.
extension RecordingChatPresenter: ChatSessionObserver {}

// MARK: - Presentation log

/// The events of several recording presenters in the order they were
/// presented, each with the name of the presenter that recorded it, so a test
/// asserts the order between the observers and the primary.
final class ChatPresentationLog: Sendable {
    struct Entry: Equatable, Sendable {
        let presenter: String
        let event: RecordingChatPresenter.Event
    }

    private let storage = Mutex<[Entry]>([])

    /// Everything recorded so far, in order.
    var entries: [Entry] {
        storage.withLock { $0 }
    }

    func append(_ event: RecordingChatPresenter.Event, presenter: String) {
        storage.withLock { $0.append(Entry(presenter: presenter, event: event)) }
    }

    func clear() {
        storage.withLock { $0.removeAll() }
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
