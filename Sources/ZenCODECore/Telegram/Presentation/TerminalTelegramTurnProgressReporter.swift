//
//  TerminalTelegramTurnProgressReporter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The only turn-scoped payloads that may be sent to Telegram, besides the
/// tool activity the reporter keeps itself
/// (``TerminalTelegramTurnProgressReporter/toolCallDidStart(id:title:)``).
///
/// The surface stays closed: streaming deltas never reach the remote chat,
/// reasoning reaches it only as a completed block (``thought(_:)``), and of a
/// tool call only its title, outcome, and elapsed time do, never its
/// arguments or result.
enum TerminalTelegramTurnPayload: Sendable {
    case agentResponse(String)
    case subAgentResponse(String)
    case tasks(String)
    case authorization(String)
    case summary(String)
    /// One completed reasoning block, sent as a plain-text message that an
    /// expandable blockquote covers by entity
    /// (see ``TerminalTelegramTurnActivity/thoughtMessage(_:)``).
    case thought(String)
    /// The turn's sub-agent status, one message edited in place.
    case subAgentStatus(String)

    var text: String {
        switch self {
        case let .agentResponse(text),
             let .subAgentResponse(text),
             let .tasks(text),
             let .authorization(text),
             let .summary(text),
             let .thought(text),
             let .subAgentStatus(text):
            text
        }
    }
}

/// The wire of the turn messages a reporter sends besides its text messages:
/// the activity and sub-agent status messages, created as plain text with a
/// receipt and edited in place as plain text, and the thinking messages.
/// Production builds it in ``TelegramChannel/makeTurnProgressReporter(for:)``
/// on the reporter's wire fence, each send validated against the route lease.
struct TerminalTelegramTurnActivityWire: Sendable {
    /// Creates a plain-text message and returns its Telegram message id.
    let sendPlainMessage: @Sendable (String, Int64) async throws -> Int
    /// Replaces the text of a message the reporter owns, as plain text.
    let editPlainMessage: @Sendable (String, Int64, Int) async throws -> Void
    /// Sends one reasoning block, reporting whether it was delivered.
    let sendThought: @Sendable (String, Int64) async -> Bool
}

/// Single FIFO outbound channel for one turn presented in Telegram.
///
/// All remote turn output travels through this actor so root responses,
/// reasoning blocks, tool activity, task updates, the sub-agent status,
/// delegated responses, authorization requests, the final response, and its
/// change summary retain their production order. Bot control messages
/// intentionally bypass it.
///
/// Root responses are the only payload this actor buffers as deltas. They are
/// aggregated as they stream and published as a single message at the
/// boundary that proves the block complete (the next tool call). The buffer
/// is text only: reasoning, tool identity, arguments, and results never reach
/// it. A reasoning block arrives already complete (``TerminalTelegramTurnPayload/thought(_:)``).
///
/// Tool calls are shown in activity messages edited in place, one row per
/// call: its title, then only its outcome and elapsed time
/// (``toolCallDidStart(id:title:)``, ``toolCallDidComplete(id:failed:elapsed:)``).
/// The time is the one the tool executor measured for the call
/// (``DirectAgentToolResult/elapsed``). An activity message is closed by every queued payload
/// that creates a new message in the chat (a response, a reasoning block,
/// the first task-graph card, the creation of the sub-agent status, a
/// delegated response, an authorization, the outcome, the summary): the next
/// call opens a new one below it. Editing a message in
/// place (a later task-graph card, a later sub-agent status) closes nothing.
/// A call's outcome is written in the row of the message it started in, even
/// when that message is closed. An activity message whose creation had an
/// unknown outcome is fenced for good (see
/// ``TerminalTelegramEditableMessageLedger``): once the drain learns it, the
/// message is closed too, so the next call opens a new one instead of adding
/// rows nobody sees; the fenced message is never edited nor adopted. The
/// sub-agent status is one message per reporter, edited in place.
///
/// Edits are coalesced in the queue: an edit of a message whose previous edit
/// is still the last queued item replaces it, so a burst of calls produces a
/// few edits paced by the wire's rate governor, and an edit never overtakes
/// an item queued before it. Activity and status messages stay in the chat
/// when the reporter retires; only the progress card is deleted. No timer or
/// task besides the drain exists, so ``retire()`` stops everything.
actor TerminalTelegramTurnProgressReporter {
    /// Telegram rejects messages beyond ~4096 characters; stay below it.
    static let maximumMessageLength = 3_900
    /// The room, in UTF-16 code units, an activity message keeps for the
    /// elapsed time of every row still running: a space and the time
    /// (``ToolCallPresentation/elapsedTimeText(_:)`` is at most 11 units below
    /// about three years). A completion whose time would still not fit is
    /// written without it, so the message limit is never exceeded.
    static let elapsedTimeReserve = 12

    /// One queued wire effect.
    private enum QueuedItem {
        /// A text message, with the continuation awaiting its delivery.
        case message(text: String, deliveryContinuation: CheckedContinuation<Bool, Never>?)
        /// An update of the task-graph progress card.
        case progressCard(text: String)
        /// A reasoning block.
        case thought(text: String)
        /// The text an editable message shows from now on.
        case editable(TerminalTelegramEditableMessageLedger, text: String)

        /// Resumes the delivery continuation, if any, as undelivered.
        func abandon() {
            if case let .message(_, continuation) = self {
                continuation?.resume(returning: false)
            }
        }
    }

    /// One activity message: its ledger and its rows, in call order.
    private struct ActivityBlock {
        let ledger: TerminalTelegramEditableMessageLedger
        var rows: [ActivityRow]

        var text: String {
            TerminalTelegramTurnProgressReporter.activityText(rows)
        }
    }

    private struct ActivityRow {
        let title: String
        var outcome: TerminalTelegramTurnActivity.ToolOutcome?
        var elapsed: Duration?
    }

    /// Where the row of a running call is: its block and its index there.
    private struct ActivityRowLocation {
        let block: Int
        let row: Int
    }

    let chatID: Int64
    /// Returns `true` when the message reached Telegram. Delivery status is part
    /// of the authorization contract: an undeliverable request must fail closed.
    let sendMessage: @Sendable (String, Int64) async -> Bool
    private let sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)?
    private var draftStreamer: TerminalTelegramDraftStreamer?
    private let progressCards: TerminalTelegramProgressCardLedger?
    /// The wire of the activity, status, and thinking messages; without it
    /// they are dropped.
    private let activityWire: TerminalTelegramTurnActivityWire?
    private let wireFence: TerminalTelegramWireFence
    private let waitForWireQuiescence: (@Sendable (TerminalTelegramWireFence) async -> Void)?

    private var queue: [QueuedItem] = []
    /// The activity messages of the reporter, oldest first.
    private var activityBlocks: [ActivityBlock] = []
    /// The activity message the next call joins; `nil` once a new message
    /// closed it.
    private var openActivityBlock: Int?
    /// The rows of the calls still running, by call id.
    private var runningToolCallRows: [String: ActivityRowLocation] = [:]
    /// The sub-agent status message, once created.
    private var subAgentStatus: TerminalTelegramEditableMessageLedger?
    private var lastSubAgentStatusText: String?
    /// `true` once a task-graph card was queued: the card exists from then
    /// on and is edited in place.
    private var hasQueuedProgressCard = false
    /// Root response text aggregated since the last boundary.
    private var pendingAgentResponse = ""
    private var isDraining = false
    private var drainTask: Task<Void, Never>?
    private var isRetired = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Bool,
        sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)? = nil,
        progressCards: TerminalTelegramProgressCardLedger? = nil,
        activityWire: TerminalTelegramTurnActivityWire? = nil,
        wireFence: TerminalTelegramWireFence,
        waitForWireQuiescence: (@Sendable (TerminalTelegramWireFence) async -> Void)? = nil
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
        self.sendDraft = sendDraft
        self.progressCards = progressCards
        self.activityWire = activityWire
        self.wireFence = wireFence
        self.waitForWireQuiescence = waitForWireQuiescence
        if let sendDraft {
            draftStreamer = TerminalTelegramDraftStreamer(chatID: chatID, sendDraft: sendDraft)
        }
    }

    /// Queues a permitted turn payload without waiting for delivery.
    ///
    /// A task graph updates the progress card when the reporter has one; a
    /// reasoning block and the sub-agent status need the activity wire and
    /// are dropped without it.
    func enqueue(_ payload: TerminalTelegramTurnPayload) {
        switch payload {
        case let .tasks(text) where progressCards != nil:
            enqueueProgressCard(text)
        case let .thought(text):
            enqueueThought(text)
        case let .subAgentStatus(text):
            enqueueSubAgentStatus(text)
        default:
            enqueue(payload.text, deliveryContinuation: nil)
        }
    }

    // MARK: - Tool activity

    /// Shows a root tool call that started: a row with `title` and a neutral
    /// marker, in the open activity message, or in a new one when no message
    /// is open or the row would not fit. Without the activity wire, or once
    /// retired, nothing happens.
    func toolCallDidStart(id: String, title: String) {
        guard !isRetired, activityWire != nil else { return }
        let row = ActivityRow(title: TerminalTelegramTurnActivity.toolTitle(title), outcome: nil, elapsed: nil)
        let blockIndex: Int
        if let open = openActivityBlock,
           Self.fits(activityBlocks[open].rows + [row]) {
            blockIndex = open
            activityBlocks[open].rows.append(row)
        } else if let ledger = makeEditableMessageLedger() {
            blockIndex = activityBlocks.count
            activityBlocks.append(ActivityBlock(ledger: ledger, rows: [row]))
            openActivityBlock = blockIndex
        } else {
            return
        }
        runningToolCallRows[id] = ActivityRowLocation(
            block: blockIndex, row: activityBlocks[blockIndex].rows.count - 1
        )
        let block = activityBlocks[blockIndex]
        enqueueEdit(of: block.ledger, text: block.text)
    }

    /// Writes the outcome of a call that ``toolCallDidStart(id:title:)``
    /// showed in its row, in the message it started in, with `elapsed`, the
    /// time the tool executor measured for the call
    /// (``DirectAgentToolResult/elapsed``); the time is left out when it is
    /// `nil` or when the message would exceed ``maximumMessageLength`` with
    /// it. A call the reporter did not show, or one that already ended,
    /// changes nothing.
    func toolCallDidComplete(id: String, failed: Bool, elapsed: Duration?) {
        guard !isRetired, let location = runningToolCallRows.removeValue(forKey: id) else { return }
        var rows = activityBlocks[location.block].rows
        rows[location.row].outcome = failed ? .failed : .succeeded
        rows[location.row].elapsed = elapsed
        if Self.activityText(rows).utf16.count > Self.maximumMessageLength {
            rows[location.row].elapsed = nil
        }
        activityBlocks[location.block].rows = rows
        let block = activityBlocks[location.block]
        enqueueEdit(of: block.ledger, text: block.text)
    }

    /// Whether an activity message with `rows` stays within the message
    /// limit, counted in UTF-16 code units as Telegram counts it, keeping
    /// ``elapsedTimeReserve`` for every row still running.
    private static func fits(_ rows: [ActivityRow]) -> Bool {
        let reserve = rows.count(where: { $0.outcome == nil }) * elapsedTimeReserve
        return activityText(rows).utf16.count + reserve <= maximumMessageLength
    }

    /// The text of an activity message: one row per call, in call order.
    private static func activityText(_ rows: [ActivityRow]) -> String {
        rows.map {
            TerminalTelegramTurnActivity.toolRow(title: $0.title, outcome: $0.outcome, elapsed: $0.elapsed)
        }
        .joined(separator: "\n")
    }

    private func makeEditableMessageLedger() -> TerminalTelegramEditableMessageLedger? {
        guard let activityWire else { return nil }
        return TerminalTelegramEditableMessageLedger(
            chatID: chatID,
            send: activityWire.sendPlainMessage,
            edit: activityWire.editPlainMessage
        )
    }

    /// The next call opens a new activity message.
    private func closeActivityMessage() {
        openActivityBlock = nil
    }

    /// `ledger` is fenced for good: when it is the open activity message,
    /// the next call opens a new one. Rows that joined it before the drain
    /// learned it stay where they are, unseen: the fenced message may exist
    /// in the chat, so nothing of it is moved or sent again.
    private func editableMessageWasFenced(_ ledger: TerminalTelegramEditableMessageLedger) {
        guard let open = openActivityBlock, activityBlocks[open].ledger === ledger else { return }
        closeActivityMessage()
    }

    // MARK: - Status, reasoning, and card

    /// Shows `text` as the turn's sub-agent status: the first status creates
    /// the message (closing the activity message), every later one edits it.
    /// A status equal to the last one changes nothing.
    private func enqueueSubAgentStatus(_ text: String) {
        guard !isRetired, let text = text.nilIfBlank else { return }
        let bounded = String(text.prefix(Self.maximumMessageLength))
        guard bounded != lastSubAgentStatusText else { return }
        let ledger: TerminalTelegramEditableMessageLedger
        if let subAgentStatus {
            ledger = subAgentStatus
        } else {
            guard let created = makeEditableMessageLedger() else { return }
            closeActivityMessage()
            subAgentStatus = created
            ledger = created
        }
        lastSubAgentStatusText = bounded
        enqueueEdit(of: ledger, text: bounded)
    }

    /// Queues one completed reasoning block, bounded to the message limit.
    private func enqueueThought(_ text: String) {
        guard !isRetired, activityWire != nil,
              let thought = TerminalTelegramTurnActivity.boundedThought(text) else { return }
        closeActivityMessage()
        append(.thought(text: thought))
    }

    /// Queues an update of the progress card; the first one creates the card
    /// and closes the activity message.
    private func enqueueProgressCard(_ text: String) {
        guard !isRetired, let text = text.nilIfBlank else { return }
        if !hasQueuedProgressCard {
            hasQueuedProgressCard = true
            closeActivityMessage()
        }
        append(.progressCard(text: String(text.prefix(Self.maximumMessageLength))))
    }

    /// Queues the text an editable message shows, replacing the previous one
    /// when it is still the last queued item.
    private func enqueueEdit(of ledger: TerminalTelegramEditableMessageLedger, text: String) {
        if case let .editable(queuedLedger, _)? = queue.last, queuedLedger === ledger {
            queue[queue.count - 1] = .editable(ledger, text: text)
            return
        }
        append(.editable(ledger, text: text))
    }

    // MARK: - Root response buffer

    /// `true` when aggregated root response text is waiting for its boundary.
    var hasPendingAgentResponse: Bool {
        !pendingAgentResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Aggregates one visible root response delta.
    ///
    /// Nothing is queued here: a delta is not yet a response. The buffer is
    /// bounded by the per-message limit so a long block cannot grow unbounded.
    func appendAgentResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        let remainingCount = Self.maximumMessageLength - pendingAgentResponse.count
        guard remainingCount > 0 else {
            return
        }
        pendingAgentResponse.append(contentsOf: delta.prefix(remainingCount))
        if let draftStreamer { await draftStreamer.append(delta) }
    }

    /// Publishes the aggregated root response as one intermediate message.
    ///
    /// Called at the boundary that proves the block complete, so the remote
    /// chat receives the same response the terminal rendered before the tool.
    ///
    /// - Returns: `true` when a message was queued.
    @discardableResult
    func publishPendingAgentResponseAtBoundary() async -> Bool {
        let text = pendingAgentResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAgentResponse.removeAll(keepingCapacity: true)
        await rotateDraftStreamer()
        guard !text.isEmpty else {
            return false
        }
        enqueue(.agentResponse(text))
        return true
    }

    /// Returns the aggregated trailing root response without queueing it.
    ///
    /// The finalization path reads it to send the turn's final response
    /// alone, instead of the accumulated turn text that already contains every
    /// intermediate response published at its own boundary.
    func pendingAgentResponseText() -> String {
        pendingAgentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the aggregated root response without publishing it.
    ///
    /// Trailing content that no tool call followed belongs to the turn's final
    /// response, which is delivered once by the finalization path; discarding
    /// it here is what keeps that response from being sent twice.
    func discardPendingAgentResponse() async {
        pendingAgentResponse.removeAll(keepingCapacity: false)
        await rotateDraftStreamer()
    }

    func ownsStoppedDraft(chatID: Int64, draftID: Int) async -> Bool {
        await draftStreamer?.owns(chatID: chatID, draftID: draftID) == true
    }

    /// Internal observability for deterministic correlation tests.
    func draftStreamerIDForTesting() async -> Int? {
        draftStreamer?.draftID
    }

    /// Fences draft/card activity for finish, error, cancellation, rebind and
    /// teardown. Progress cards are deleted; persistent turn messages remain,
    /// the activity and sub-agent status messages included, which receive no
    /// further edit: a call still running keeps its neutral marker and gets
    /// no time, since only its result would carry one.
    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        // Synchronous epoch invalidation happens before any suspension in retire,
        // so an already-extracted delayed send is fenced at service admission.
        wireFence.invalidate()
        pendingAgentResponse.removeAll()
        let abandoned = queue
        queue.removeAll()
        for item in abandoned {
            item.abandon()
        }
        let task = drainTask
        task?.cancel()
        let editableMessages = activityBlocks.map(\.ledger) + (subAgentStatus.map { [$0] } ?? [])
        openActivityBlock = nil
        runningToolCallRows.removeAll()
        for ledger in editableMessages {
            await ledger.retire()
        }
        await draftStreamer?.finish()
        draftStreamer = nil
        await progressCards?.retire(deleteMessage: true)
    }

    /// Replacement/invalidation barrier. Revocation happens synchronously in
    /// `retire()`; this join is deliberately separate so ordinary completion can
    /// retire without waiting on a stale producer, while a new turn cannot adopt
    /// ownership until the old reporter has no send in flight.
    func revokeAndWait() async {
        await retire()
        await waitForWireQuiescence?(wireFence)
    }

    /// Teardown barrier. Unlike turn-to-turn `retire()`, stop must not return
    /// while a reporter send admitted by the retired lifecycle is still alive.
    func shutdown() async {
        await revokeAndWait()
    }

    private func rotateDraftStreamer() async {
        let previous = draftStreamer
        if let previous { await previous.finish() }
        if let sendDraft {
            draftStreamer = TerminalTelegramDraftStreamer(chatID: chatID, sendDraft: sendDraft)
        } else {
            draftStreamer = nil
        }
    }

    /// Queues an authorization payload and waits for its delivery result.
    ///
    /// - Returns: `true` when Telegram accepted the message.
    @discardableResult
    func send(_ payload: TerminalTelegramTurnPayload) async -> Bool {
        guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return await withCheckedContinuation { continuation in
            enqueue(payload.text, deliveryContinuation: continuation)
        }
    }

    /// Waits until every queued payload has been delivered.
    func flush() async {
        guard isDraining || !queue.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    /// Queues a text message, closing the activity message: it is a new
    /// message in the chat.
    private func enqueue(
        _ message: String,
        deliveryContinuation: CheckedContinuation<Bool, Never>?
    ) {
        guard !isRetired else {
            deliveryContinuation?.resume(returning: false)
            return
        }
        guard let text = message.nilIfBlank else {
            deliveryContinuation?.resume(returning: false)
            return
        }
        closeActivityMessage()
        append(.message(
            text: String(text.prefix(Self.maximumMessageLength)),
            deliveryContinuation: deliveryContinuation
        ))
    }

    private func append(_ item: QueuedItem) {
        queue.append(item)
        startDrainingIfNeeded()
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else {
            return
        }
        isDraining = true
        drainTask = Task(name: "ZenCODE.Telegram.progress-drain") { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let item = nextItem() {
            guard !Task.isCancelled, !isRetired else {
                item.abandon()
                continue
            }
            switch item {
            case let .message(text, deliveryContinuation):
                let delivered = await sendMessage(text, chatID)
                deliveryContinuation?.resume(returning: delivered)
            case let .progressCard(text):
                if let progressCards {
                    await progressCards.update(text: text)
                }
            case let .thought(text):
                _ = await activityWire?.sendThought(text, chatID)
            case let .editable(ledger, text):
                if await !ledger.update(text: text) {
                    editableMessageWasFenced(ledger)
                }
            }
        }
    }

    private func nextItem() -> QueuedItem? {
        guard !queue.isEmpty else {
            isDraining = false
            drainTask = nil
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return nil
        }
        return queue.removeFirst()
    }
}