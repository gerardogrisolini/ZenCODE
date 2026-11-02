//
//  TelegramChannel+Presenter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The presenter of a ``TelegramChannel``: the slot's presenter forwards the
/// session's output to it while the channel drives the slot (see
/// ``ChatSlotPresenter``), and tells it when a turn started on the primary
/// channel moves onto Telegram.
///
/// It sends the session's output to the linked chat: a reasoning block is
/// aggregated and sent as one thinking message once the next event closes
/// it; a root response is buffered by the turn's reporter and published at
/// the tool call that follows it, or before a reasoning block that the next
/// content closes, so the chat receives them in the order they were
/// written; each root tool call becomes a row of the turn's activity
/// message, with its title and then its outcome; the task-graph and
/// sub-agent overviews the controller publishes go through the reporter's
/// ordered queue; the ending of the turn (``presentTurnEnding(_:)``) retires
/// the reporter with the outcome and the file-change summary.
///
/// Like the terminal, it asks the controller for the sub-agent overview when
/// an `agent.*` call starts and when it settles, runs the controller's
/// refresh while a sub-agent call executes, and publishes once more when the
/// model work ends (``turnWillFinish()``). Like the terminal, it reserves
/// every publication before the controller reads the snapshots, so one that
/// a later one overtook presents nothing. Like the terminal's, its
/// presentation is deduplicated by signature for the presenter's whole life:
/// an overview equal to the last one presented sends nothing, in this turn or
/// a later one. A changed overview with agents becomes the turn's
/// `🤖 Sub-agent` status message, created once per turn and edited in place,
/// and each partial (💬) or completed (✅) response not sent yet becomes a
/// message of its own. What the sub-agents already show when the channel
/// starts driving the slot, which the primary channel showed, is marked as
/// presented and never sent (``channelDidStartDriving()``). The publications
/// it asks for and the refresh it starts publish only while the channel
/// drives the slot, and the refresh stops when the call settles, when the
/// turn finishes or its reporting ends, and when the channel stops driving
/// the slot.
///
/// While a remote command runs, it collects the text of the session and
/// workflow notices the command produces, so the command can answer with them
/// in the chat; outside a command, a notice is sent to the chat as it comes.
///
/// The presenter holds the channel weakly: the channel holds it.
@ChatSessionActor
final class TelegramChannelPresenter: ChatSlotChannelPresenter {
    /// How many sub-agent responses the presenter remembers as sent, the
    /// least recently presented forgotten first.
    nonisolated static let maximumRememberedSubAgentResponses = 512

    weak var channel: TelegramChannel?
    /// The notice texts collected since ``beginNoticeCapture()``, or `nil`
    /// when no remote command is collecting them.
    private var capturedNotices: [String]?
    /// The sub-agent responses already sent, or marked as sent by the
    /// backlog (``channelDidStartDriving()``), by their token, with the tick
    /// of ``subAgentResponseClock`` at which an overview last presented
    /// them, so a republished overview does not repeat them, in this turn or
    /// a later one: the overview keeps the agents of its wave, completed
    /// ones included, across turns. At most
    /// ``maximumRememberedSubAgentResponses``, the least recently presented
    /// forgotten first: every presentation refreshes the responses it shows
    /// before it remembers new ones (``rememberSubAgentResponses(_:)``), so a
    /// response the overview keeps showing is never forgotten, however many
    /// partial revisions arrive meanwhile.
    private var rememberedSubAgentResponses: [String: UInt64] = [:]
    private var subAgentResponseClock: UInt64 = 0
    /// What the sub-agents showed when the current drive of the slot began,
    /// and whether it was marked as presented yet (see
    /// ``channelDidStartDriving()``).
    private var subAgentBacklog = SubAgentBacklogState.notCaptured
    /// Advanced every time the channel stops driving the slot, so a
    /// publication that waited for the backlog of a drive that ended
    /// presents nothing.
    private var subAgentDriveGeneration: UInt64 = 0
    /// The signature of the last sub-agent overview presented to a turn
    /// (``presentationSignature(signature:tokens:)``), or marked as presented by the
    /// backlog, for the presenter's whole life: an equal overview sends
    /// nothing, as the terminal writes nothing for an unchanged section.
    private var lastPresentedSubAgentOverviewSignature: String?
    /// The revision of the last sub-agent publication the presenter reserved
    /// (``reserveSubAgentOverviewPublication()``); the next one is greater.
    /// Its revisions are negative, so they never meet the terminal's, which
    /// start from 1 (see ``isOwnSubAgentPublication(_:)``).
    private var lastReservedSubAgentPublicationRevision = Int.min
    /// The revision of the latest publication of its own the presenter let
    /// through, whatever it then sent: one reserved before it was overtaken
    /// and presents nothing (see
    /// ``presentSubAgentOverview(_:origin:publication:)``).
    private var lastAdmittedSubAgentPublicationRevision: Int?
    /// The controller's refresh the presenter started, until it stops it.
    private var ownedSubAgentRefresh: OwnedSubAgentRefresh?
    /// Where every publication the presenter asks the controller for goes
    /// (around a sub-agent call, at the end of the model work, and the
    /// ticks of the refresh it starts): this presenter, while its channel
    /// drives the slot. One path, so none publishes after the slot changed
    /// hands.
    private lazy var subAgentRefreshTarget = TelegramSubAgentRefreshTarget(presenter: self)

    /// A refresh the presenter started, on the controller that runs it.
    private struct OwnedSubAgentRefresh {
        weak var controller: ChatSessionController?
        let task: Task<Void, Never>
    }

    /// The backlog of one drive of the slot.
    private enum SubAgentBacklogState {
        /// Not captured yet: the drive has not begun, or no publication and
        /// no ``channelDidStartDriving()`` came since it began.
        case notCaptured
        /// ``channelDidStartDriving()`` is reading it.
        case reading(Task<SubAgentBacklog, Never>)
        /// Marked as presented, or nothing to mark: nothing more to do until
        /// the drive ends.
        case applied
    }

    /// What the sub-agents show at one moment, as the presenter marks it:
    /// the tokens of their responses and, with an agent, the presentation
    /// signature of their overview.
    private struct SubAgentBacklog: Sendable {
        let responseTokens: [String]
        let presentationSignature: String?

        init(_ overview: ChatSubAgentOverview) {
            let tokens = TelegramChannelPresenter.subAgentResponses(of: overview).map(\.token)
            responseTokens = tokens
            presentationSignature = overview.snapshots.isEmpty
                ? nil
                : TelegramChannelPresenter.presentationSignature(
                    signature: overview.signature, tokens: tokens
                )
        }
    }

    /// A partial (💬) or completed (✅) response of a sub-agent, as the
    /// presenter sends it.
    struct SubAgentResponse: Sendable, Equatable {
        let token: String
        let heading: String
        let markdown: String
    }

    init() {}

    // MARK: - Turn

    func turnWillStart(_ request: ChatTurnRequest) async {
        await channel?.beginTurn(adoptingStreamingBlock: false)
    }

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {
        // The block streaming now was sent as context by the handover; its
        // remaining deltas are suppressed until the next boundary, and so is
        // the reasoning streaming meanwhile. The handover sends no reasoning:
        // the block of a turn that moved while it reasoned starts with what
        // it reasoned so far.
        let streamsContent = !turn.liveAssistantText.isEmpty
        await channel?.beginTurn(
            adoptingStreamingBlock: streamsContent,
            liveThought: streamsContent ? "" : turn.liveThought
        )
    }

    func presentThought(_ thought: String) async {
        channel?.appendThoughtDelta(thought)
    }

    func presentAssistantContent(_ content: String) async {
        // Assistant content closes the reasoning block that preceded it; a
        // block that is sent is a boundary of the root response written
        // before it, which goes out first.
        await channel?.closeThoughtBlockBeforeAssistantContent()
        await channel?.appendRootResponseDelta(content)
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        guard let channel else { return }
        // The tool call closes the root response that preceded it, then the
        // reasoning still open (written after that response), and only then
        // shows itself: its title, never its arguments.
        await channel.publishRootResponseAtToolBoundary()
        await channel.closeThoughtBlock()
        await channel.presentToolCallActivityStarted(toolCall)
        await publishSubAgentOverview(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            startSubAgentOverviewRefreshIfNeeded()
        }
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await channel?.presentToolCallActivityCompleted(toolCall, result: result)
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        await publishSubAgentOverview(relatedToolName: toolCall.name)
        if DirectSubAgentRuntime.isSubAgentToolName(toolCall.name) {
            // As the terminal does: the refresh stops, whoever started it,
            // and the latest overview is published once, on the target that
            // publishes only while the channel drives the slot.
            ownedSubAgentRefresh = nil
            await channel?.controller?.stopSubAgentOverviewRefresh(presenter: subAgentRefreshTarget)
        }
    }

    func turnWillContinueAutomatically() async {
        // An automatic `/goal` continuation closes the block like a boundary.
        await channel?.publishRootResponseAtToolBoundary()
        await channel?.closeThoughtBlock()
    }

    func turnWillFinish() async {
        // The end of the model work closes the reasoning block. As the
        // terminal does, the refresh stops, whoever started it, and the
        // overview is published once, on the target that publishes only
        // while the channel drives the slot: an unchanged one sends nothing.
        await channel?.closeThoughtBlock()
        ownedSubAgentRefresh = nil
        await channel?.controller?.stopSubAgentOverviewRefresh(presenter: subAgentRefreshTarget)
    }

    func presentTurnEnding(_ ending: ChatTurnEnding) async {
        await channel?.finishTurn(ending: ending)
    }

    // MARK: - Sub-agent overview

    /// Asks the controller for the sub-agent overview around a tool call, on
    /// ``subAgentRefreshTarget``: nothing for a tool that is not a sub-agent
    /// tool, and nothing once the channel no longer drives the slot.
    private func publishSubAgentOverview(relatedToolName: String) async {
        guard DirectSubAgentRuntime.isSubAgentToolName(relatedToolName),
              let controller = channel?.controller else { return }
        await controller.publishSubAgentOverviewIfChanged(
            relatedToolName: relatedToolName, presenter: subAgentRefreshTarget
        )
    }

    /// Starts the controller's refresh on ``subAgentRefreshTarget``, unless a
    /// refresh already runs: the terminal's, started before the turn moved
    /// here, publishes through the slot's presenter, which forwards it here.
    private func startSubAgentOverviewRefreshIfNeeded() {
        guard let controller = channel?.controller,
              controller.subAgentOverviewRefreshTask == nil else { return }
        controller.startSubAgentOverviewRefreshIfNeeded(presenter: subAgentRefreshTarget)
        if let task = controller.subAgentOverviewRefreshTask {
            ownedSubAgentRefresh = OwnedSubAgentRefresh(controller: controller, task: task)
        }
    }

    /// Stops the refresh the presenter started, if it still runs, and waits
    /// for a tick in flight, without publishing: the turn's reporting ended,
    /// or the channel stopped driving the slot. A refresh another channel
    /// started since is left alone. Idempotent.
    func stopOwnedSubAgentOverviewRefresh() async {
        guard let owned = ownedSubAgentRefresh else { return }
        ownedSubAgentRefresh = nil
        guard let controller = owned.controller else {
            owned.task.cancel()
            await owned.task.value
            return
        }
        guard controller.subAgentOverviewRefreshTask == owned.task else { return }
        await controller.cancelSubAgentOverviewRefresh()
    }

    // MARK: - Driving

    /// The channel started driving the slot: the one place of the policy for
    /// what the sub-agents already show then (the backlog, which the primary
    /// channel, the terminal or the editor, showed). The policy marks it as
    /// presented: each partial (💬) and completed (✅) response present then
    /// is remembered as sent, and the presentation signature of their
    /// overview as the last presented, so none of them reaches the chat and
    /// an unchanged overview of those agents creates no `🤖 Sub-agent`
    /// status; the responses and revisions that come later, and an overview
    /// that changes, do.
    ///
    /// The backlog is read from the controller here, in a task the next
    /// publication waits for, so it is marked before that publication is
    /// compared with the last signature. The snapshots live behind the
    /// runtime, so the read lands one hop after the channel started
    /// driving: a response that completes during that hop is part of the
    /// backlog and does not reach the chat. That window cannot be closed
    /// from the presenter.
    ///
    /// The backlog is captured once per drive. A publication that reaches
    /// the presenter while the channel already drives the slot, before this
    /// call (a tick of the primary channel's refresh landing between the
    /// switch of the slot and ``TelegramChannel/startDriving()``, while the
    /// turn that moved here begins), captures it first: its own overview is
    /// what the sub-agents show then, so it is marked and presents nothing,
    /// and this call reads nothing more. Without a session there is nothing
    /// to mark.
    func channelDidStartDriving() {
        guard case .notCaptured = subAgentBacklog else { return }
        guard let controller = channel?.controller else {
            subAgentBacklog = .applied
            return
        }
        subAgentBacklog = .reading(Task(name: "ZenCODE.Telegram.sub-agent-backlog") {
            @ChatSessionActor [weak controller] in
            guard let controller else {
                return SubAgentBacklog(ChatSubAgentOverview(snapshots: []))
            }
            return SubAgentBacklog(await controller.currentSubAgentOverview())
        })
    }

    /// The channel stopped driving the slot: the refresh the presenter
    /// started stops, so nothing keeps publishing here, and the drive's
    /// backlog is forgotten (a read in flight is awaited and dropped), so the
    /// next drive captures its own.
    func channelDidStopDriving() async {
        subAgentDriveGeneration &+= 1
        let backlog = subAgentBacklog
        subAgentBacklog = .notCaptured
        if case let .reading(task) = backlog {
            task.cancel()
            _ = await task.value
        }
        await stopOwnedSubAgentOverviewRefresh()
    }

    /// Marks the drive's backlog as presented before `overview`, the
    /// publication that arrived, is compared with the last signature: the
    /// backlog ``channelDidStartDriving()`` reads, once it is read, or
    /// `overview` itself when it is the first thing the presenter receives
    /// while the channel drives the slot. Without a drive (the channel does
    /// not drive the slot, and none began) nothing is marked.
    ///
    /// - Returns: `false` when the drive ended while the publication waited
    ///   for its backlog: the publication presents nothing.
    private func markSubAgentBacklogAsPresented(before overview: ChatSubAgentOverview) async -> Bool {
        switch subAgentBacklog {
        case .applied:
            return true
        case .notCaptured:
            if channel?.drivesSlot == true {
                subAgentBacklog = .applied
                markAsPresented(SubAgentBacklog(overview))
            }
            return true
        case let .reading(task):
            let generation = subAgentDriveGeneration
            let backlog = await task.value
            guard generation == subAgentDriveGeneration else { return false }
            if case let .reading(current) = subAgentBacklog, current == task {
                subAgentBacklog = .applied
                markAsPresented(backlog)
            }
            return true
        }
    }

    /// Remembers what `backlog` shows as presented, without sending it.
    private func markAsPresented(_ backlog: SubAgentBacklog) {
        _ = rememberSubAgentResponses(backlog.responseTokens)
        if let signature = backlog.presentationSignature {
            lastPresentedSubAgentOverviewSignature = signature
        }
    }

    // MARK: - Overviews

    func presentTaskGraphOverview(
        _ overview: ChatTaskGraphOverview?,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard let channel, let overview else { return }
        guard origin == .explicit || overview.isSignificant else { return }
        let plainText = TerminalANSIText.stripANSI(
            TerminalChat.taskGraphMarkdown(graph: overview.graph, tasks: overview.tasks, ansiEnabled: false)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plainText.isEmpty else { return }
        await channel.enqueueOverview(
            .tasks("📋 Task graph\n\n\(plainText)"),
            taskGraphSignature: overview.signature
        )
    }

    /// Reserves the next publication of the sub-agent overview, before the
    /// controller reads the snapshots: its revision is greater than every
    /// earlier one of the presenter's, and negative, so a reservation the
    /// presenter took is told from the terminal's, whose revisions start
    /// from 1, when a channel switch hands one to the other.
    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        lastReservedSubAgentPublicationRevision += 1
        return ChatOverviewPublication(revision: lastReservedSubAgentPublicationRevision)
    }

    /// Whether `revision` is one the presenter reserves: a negative one.
    nonisolated static func isOwnSubAgentPublication(_ revision: Int) -> Bool {
        revision < 0
    }

    /// Whether a publication of the presenter's own reserved with `revision`
    /// was overtaken: a later one of its own went through already.
    private func isOvertaken(_ revision: Int) -> Bool {
        guard let admitted = lastAdmittedSubAgentPublicationRevision else { return false }
        return revision < admitted
    }

    /// Presents the session's sub-agents to the turn in progress: the turn's
    /// `🤖 Sub-agent` status message, created at the first overview the turn
    /// presents and edited in place afterwards, then each partial (💬) and
    /// completed (✅) response not sent yet, as a message of its own.
    ///
    /// A publication of the presenter's own (its `publication` was reserved
    /// by ``reserveSubAgentOverviewPublication()``) that a later one of its
    /// own overtook presents nothing, and marks nothing: the controller
    /// reserves before it reads the snapshots, so a later reservation read
    /// them later, even when its read returned first. It is checked before
    /// the backlog is awaited, and again once it is, since the overtaking
    /// publication may have gone through meanwhile; one that goes through
    /// overtakes the earlier ones even when it sends nothing. A reservation
    /// of another channel (the slot's presenter forwards the reservation and
    /// the presentation to the channel that drives the slot at each moment,
    /// so a switch in between hands one over), or none, is presented as it
    /// comes: it is neither checked nor overtakes anything.
    ///
    /// The drive's backlog is marked as presented first (see
    /// ``channelDidStartDriving()``), so it takes part in the comparison
    /// below. Then nothing is presented, and nothing is remembered, without
    /// a reporter sending the turn or without an agent; an overview whose
    /// ``presentationSignature(signature:tokens:)`` equals the last one
    /// presented sends nothing either.
    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        let ownRevision = publication.map(\.revision).flatMap {
            Self.isOwnSubAgentPublication($0) ? $0 : nil
        }
        if let ownRevision, isOvertaken(ownRevision) { return }
        guard await markSubAgentBacklogAsPresented(before: overview) else { return }
        if let ownRevision {
            guard !isOvertaken(ownRevision) else { return }
            lastAdmittedSubAgentPublicationRevision = ownRevision
        }
        guard let channel, channel.activeProgressReporter != nil,
              !overview.snapshots.isEmpty else { return }
        let responses = Self.subAgentResponses(of: overview)
        let tokens = responses.map(\.token)
        let signature = Self.presentationSignature(signature: overview.signature, tokens: tokens)
        guard signature != lastPresentedSubAgentOverviewSignature else { return }
        lastPresentedSubAgentOverviewSignature = signature
        let newResponses = rememberSubAgentResponses(tokens)
        if let status = TerminalTelegramTurnActivity.subAgentStatusText(
            rows: TerminalChat.subAgentStatusRows(overview.snapshots)
        ) {
            await channel.enqueueOverview(.subAgentStatus(status))
        }
        for response in responses where newResponses.contains(response.token) {
            guard let payload = Self.subAgentResponsePayload(
                heading: response.heading, markdown: response.markdown
            ) else { continue }
            await channel.enqueueOverview(payload)
        }
    }

    /// The identity of what the presenter shows of an overview: its
    /// `signature` and the `tokens` of its responses
    /// (``subAgentResponses(of:)``), which the signature does not carry (a
    /// new response of an agent whose rows did not change is still news).
    nonisolated static func presentationSignature(signature: String, tokens: [String]) -> String {
        ([signature] + tokens).joined(separator: "\u{1D}")
    }

    /// The partial (💬) and completed (✅) responses of `overview`, in the
    /// order the presenter sends them: the partial ones first, then the
    /// completed ones.
    nonisolated static func subAgentResponses(of overview: ChatSubAgentOverview) -> [SubAgentResponse] {
        TerminalChat.subAgentPartialResponses(overview.snapshots).map {
            SubAgentResponse(token: $0.token, heading: $0.heading, markdown: $0.markdown)
        } + TerminalChat.subAgentMarkdownResponses(overview.snapshots).map {
            SubAgentResponse(token: $0.token, heading: $0.heading, markdown: $0.markdown)
        }
    }

    /// Remembers `tokens`, the responses one overview shows, as presented
    /// now, and returns the ones that were not remembered yet: those are
    /// news. The ones already remembered are refreshed first, then the new
    /// ones are added, each pushing out the least recently presented token
    /// past ``maximumRememberedSubAgentResponses``: so a new token never
    /// pushes out a response of the same overview, and a response every
    /// overview keeps showing is never forgotten.
    private func rememberSubAgentResponses(_ tokens: [String]) -> Set<String> {
        for token in tokens where rememberedSubAgentResponses[token] != nil {
            subAgentResponseClock &+= 1
            rememberedSubAgentResponses[token] = subAgentResponseClock
        }
        var newTokens = Set<String>()
        for token in tokens where rememberedSubAgentResponses[token] == nil {
            subAgentResponseClock &+= 1
            rememberedSubAgentResponses[token] = subAgentResponseClock
            newTokens.insert(token)
            if rememberedSubAgentResponses.count > Self.maximumRememberedSubAgentResponses,
               let leastRecent = rememberedSubAgentResponses.min(by: { $0.value < $1.value })?.key {
                rememberedSubAgentResponses.removeValue(forKey: leastRecent)
            }
        }
        return newTokens
    }

    /// The payload of a sub-agent response: its heading, without the
    /// terminal's decoration, over its Markdown; `nil` for an empty response.
    nonisolated static func subAgentResponsePayload(
        heading: String,
        markdown: String
    ) -> TerminalTelegramTurnPayload? {
        let heading = TerminalANSIText.stripANSI(heading)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !markdown.isEmpty else {
            return nil
        }
        let text = heading.isEmpty ? markdown : "\(heading)\n\n\(markdown)"
        return .subAgentResponse(text)
    }

    // MARK: - Notices

    /// Starts collecting the notices the session presents, for the remote
    /// command that is about to run. A capture already in progress starts
    /// over.
    func beginNoticeCapture() {
        capturedNotices = []
    }

    /// Stops collecting and returns the text of every session and workflow
    /// notice presented since ``beginNoticeCapture()``, in order, as
    /// ``ChatSessionNoticeText`` words them. Without a capture in progress it
    /// returns no text.
    func endNoticeCapture() -> [String] {
        let notices = capturedNotices ?? []
        capturedNotices = nil
        return notices
    }

    func presentSessionNotice(_ notice: ChatSessionNotice) async {
        let text = ChatSessionNoticeText.text(for: notice)
        if capturedNotices != nil {
            capturedNotices?.append(text)
        } else {
            await channel?.sendSessionText(text)
        }
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        let text = ChatSessionNoticeText.text(for: notice)
        if capturedNotices != nil {
            capturedNotices?.append(text)
        } else {
            await channel?.sendSessionText(text)
        }
    }
}

/// The presenter every sub-agent publication a ``TelegramChannelPresenter``
/// asks the controller for goes through: the ones around a sub-agent call,
/// the one at the end of the model work, and the ticks of the refresh it
/// starts. It forwards the overview to that presenter only while its channel
/// drives the slot, so a publication that lands after another channel took
/// the slot (`/telegram off` switches the slot before it stops the channel
/// and its turn's reporter), or a tick before the channel stopped the
/// refresh, sends nothing. The reservation is the presenter's own, so its
/// publications are ordered with the ones the slot's presenter forwards to
/// it. Every other call is ignored.
@ChatSessionActor
final class TelegramSubAgentRefreshTarget: ChatSessionPresenter {
    private weak var presenter: TelegramChannelPresenter?

    init(presenter: TelegramChannelPresenter) {
        self.presenter = presenter
    }

    func reserveSubAgentOverviewPublication() async -> ChatOverviewPublication? {
        await presenter?.reserveSubAgentOverviewPublication()
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard let presenter, presenter.channel?.drivesSlot == true else { return }
        await presenter.presentSubAgentOverview(overview, origin: origin, publication: publication)
    }
}
