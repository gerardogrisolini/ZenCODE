//
//  TelegramTurnActivityTestSupport.swift
//  ZenCODE
//
//  Shared fixtures of the suites that check what a turn reporter sends
//  besides its text messages (the tool activity, the thinking messages, the
//  sub-agent status): a recorder of every wire effect of a reporter, in the
//  order its drain ran them, with synthetic receipts, a gate that holds
//  the creation of an editable message, and creations that fail with an
//  unknown outcome, and a manual clock for the tool calls' elapsed times.
//  Nothing reaches the network.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// One wire effect of a reporter, in the order its drain ran it.
enum TelegramTurnActivityEffect: Equatable, Sendable {
    /// A text message (a response, an authorization, an outcome, a summary).
    case message(String)
    /// The creation of an editable message (activity or sub-agent status),
    /// with the receipt it got.
    case create(id: Int, text: String)
    /// A creation that threw, so its outcome is unknown: no receipt.
    case createFailed(text: String)
    /// An edit of the editable message `id`.
    case edit(id: Int, text: String)
    /// A thinking message.
    case thought(String)
    /// The creation of the task-graph card.
    case cardCreate(id: Int, text: String)
    /// An edit of the task-graph card.
    case cardEdit(id: Int, text: String)
    /// The deletion of the task-graph card.
    case cardDelete(id: Int)
}

/// A manual clock for a reporter's tool-call times: it stands still until
/// ``advance(by:)`` moves it, so a row's elapsed time is exactly what a test
/// advanced between its start and its completion (`0ms` when it did not).
final class TelegramTurnActivityClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)

    init() {}

    @Sendable
    func now() -> ContinuousClock.Instant {
        instant.withLock { $0 }
    }

    func advance(by duration: Duration) {
        instant.withLock { $0 += duration }
    }
}

/// Records the wire effects of the reporters it builds
/// (``makeReporter(chatID:)``) and hands back receipts from 100 on, shared
/// by the card and the editable messages. While ``holdCreates()`` is on, the
/// creation of an editable message waits for ``releaseCreates()``, so a test
/// can queue a burst behind it; while ``holdMessages()`` is on, a text
/// message waits for ``releaseMessages()`` before it is recorded, so a test
/// can keep a reporter's flush in flight; after ``failNextCreates(_:)`` the
/// next creations throw.
actor TelegramTurnActivityWireLog {
    /// The error of a creation that failed with an unknown outcome.
    struct CreateFailure: Error {}

    private(set) var effects: [TelegramTurnActivityEffect] = []
    private var nextMessageID = 100
    private var failingCreates = 0
    private var holdsCreates = false
    private var heldCreates: [CheckedContinuation<Void, Never>] = []
    private var heldCreateWaiters: [CheckedContinuation<Void, Never>] = []
    private var holdsMessages = false
    private var heldMessages: [CheckedContinuation<Void, Never>] = []
    private var heldMessageWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// The texts of the text messages, in order.
    var messages: [String] {
        effects.compactMap {
            if case let .message(text) = $0 { return text }
            return nil
        }
    }

    /// The text each editable message shows now, by receipt.
    var editableTexts: [Int: String] {
        var texts: [Int: String] = [:]
        for effect in effects {
            switch effect {
            case let .create(id, text), let .edit(id, text):
                texts[id] = text
            default:
                break
            }
        }
        return texts
    }

    /// From now on the creation of an editable message waits.
    func holdCreates() {
        holdsCreates = true
    }

    /// Lets every held creation go on; later ones no longer wait.
    func releaseCreates() {
        holdsCreates = false
        let held = heldCreates
        heldCreates = []
        for continuation in held {
            continuation.resume()
        }
    }

    /// The next `count` creations of an editable message throw, as a send
    /// whose outcome is unknown does.
    func failNextCreates(_ count: Int = 1) {
        failingCreates = count
    }

    /// Returns once a creation waits at the gate.
    func waitUntilACreateIsHeld() async {
        guard heldCreates.isEmpty else { return }
        await withCheckedContinuation { heldCreateWaiters.append($0) }
    }

    /// From now on a text message waits before it is recorded.
    func holdMessages() {
        holdsMessages = true
    }

    /// Lets every held message go on, in order; later ones no longer wait.
    func releaseMessages() {
        holdsMessages = false
        let held = heldMessages
        heldMessages = []
        for continuation in held {
            continuation.resume()
        }
    }

    /// Returns once a text message waits at the gate.
    func waitUntilAMessageIsHeld() async {
        guard heldMessages.isEmpty else { return }
        await withCheckedContinuation { heldMessageWaiters.append($0) }
    }

    func message(_ text: String) async {
        if holdsMessages {
            await withCheckedContinuation { continuation in
                heldMessages.append(continuation)
                let waiters = heldMessageWaiters
                heldMessageWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        effects.append(.message(text))
    }

    func thought(_ text: String) {
        effects.append(.thought(text))
    }

    func create(_ text: String) async throws -> Int {
        if failingCreates > 0 {
            failingCreates -= 1
            effects.append(.createFailed(text: text))
            throw CreateFailure()
        }
        if holdsCreates {
            await withCheckedContinuation { continuation in
                heldCreates.append(continuation)
                let waiters = heldCreateWaiters
                heldCreateWaiters = []
                for waiter in waiters {
                    waiter.resume()
                }
            }
        }
        let id = takeMessageID()
        effects.append(.create(id: id, text: text))
        return id
    }

    func edit(id: Int, text: String) {
        effects.append(.edit(id: id, text: text))
    }

    func cardCreate(_ text: String) -> Int {
        let id = takeMessageID()
        effects.append(.cardCreate(id: id, text: text))
        return id
    }

    func cardEdit(id: Int, text: String) {
        effects.append(.cardEdit(id: id, text: text))
    }

    func cardDelete(id: Int) {
        effects.append(.cardDelete(id: id))
    }

    private func takeMessageID() -> Int {
        defer { nextMessageID += 1 }
        return nextMessageID
    }

    /// A reporter for `chatID` whose every wire effect lands here: its text
    /// messages, its task-graph card, its activity and status messages, and
    /// its thinking messages, behind a fence whose route always stays
    /// current. Its tool-call times come from `clock`, which stands still
    /// unless the test advances it.
    nonisolated func makeReporter(
        chatID: Int64 = 42,
        clock: TelegramTurnActivityClock = TelegramTurnActivityClock()
    ) -> TerminalTelegramTurnProgressReporter {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: chatID, userID: 7, roomID: "test-room"), generation: 1
        )
        let cards = TerminalTelegramProgressCardLedger(
            chatID: chatID,
            send: { text, _ in await self.cardCreate(text) },
            editText: { text, _, id in await self.cardEdit(id: id, text: text) },
            editMarkup: { _, _, _ in },
            delete: { _, id in await self.cardDelete(id: id) }
        )
        return TerminalTelegramTurnProgressReporter(
            chatID: chatID,
            sendMessage: { text, _ in
                await self.message(text)
                return true
            },
            progressCards: cards,
            activityWire: TerminalTelegramTurnActivityWire(
                sendPlainMessage: { text, _ in try await self.create(text) },
                editPlainMessage: { text, _, id in await self.edit(id: id, text: text) },
                sendThought: { text, _ in
                    await self.thought(text)
                    return true
                }
            ),
            wireFence: TerminalTelegramWireFence(lease: lease, lifecycleEpoch: UUID()) { candidate in
                guard candidate == lease else { throw CancellationError() }
            },
            now: clock.now
        )
    }
}

enum TelegramTurnActivityFixtures {
    /// Revokes the reporter of `channel`'s turn and installs one that records
    /// into `log`, as the turn's reporter.
    @ChatSessionActor
    @discardableResult
    static func install(
        _ log: TelegramTurnActivityWireLog, on channel: TelegramChannel
    ) async -> TerminalTelegramTurnProgressReporter {
        await channel.activeProgressReporter?.revokeAndWait()
        let reporter = log.makeReporter()
        channel.activeProgressReporter = reporter
        return reporter
    }

    /// A root tool call `name` with `arguments`.
    static func toolCall(
        id: String, name: String, arguments: [String: Any] = [:]
    ) -> DirectAgentToolCall {
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return DirectAgentToolCall(id: id, name: name, argumentsObject: arguments, argumentsJSON: json)
    }

    /// A completed result with `output`.
    static func result(_ output: String = "ok", summary: String = "ok") -> DirectAgentToolResult {
        DirectAgentToolResult(output: output, summary: summary)
    }

    /// The row title the channel shows for `toolCall`.
    static func rowTitle(_ toolCall: DirectAgentToolCall) -> String {
        TerminalTelegramTurnActivity.toolTitle(ToolCallPresentation.toolTitle(for: toolCall))
    }

    /// Whether `text` is the completed row `marker title time`, its time a
    /// token ``TerminalChat/toolElapsedTimeText(_:)`` produces: for the rows
    /// of a production reporter, whose clock is the real one.
    static func isTimedRow(_ text: String?, marker: String, title: String) -> Bool {
        let prefix = "\(marker) \(title) "
        guard let text, text.hasPrefix(prefix) else { return false }
        return isElapsedTimeToken(String(text.dropFirst(prefix.count)))
    }

    /// Whether `token` is a time ``TerminalChat/toolElapsedTimeText(_:)``
    /// produces (`1.25s`, `420ms`, `4.2ms`, `<0.01ms`, `0ms`).
    static func isElapsedTimeToken(_ token: String) -> Bool {
        token.wholeMatch(of: #/\d+\.\d{2}s|\d+(\.\d{1,2})?ms|<0\.01ms|0ms/#) != nil
    }

    /// A sub-agent snapshot: `status`, its current activity of `kind` at
    /// `revision`, and its latest response, if any.
    static func subAgent(
        id: String,
        status: DirectSubAgentRuntime.Status,
        activity: String? = nil,
        kind: DirectSubAgentRuntime.ActivityKind? = nil,
        revision: UInt64 = 0,
        toolName: String? = nil,
        toolTarget: String? = nil,
        response: String? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: id,
            role: "worker",
            status: status,
            pending: status == .running || status == .queued,
            currentActivity: activity,
            currentActivityKind: kind,
            currentActivityRevision: revision,
            currentToolName: toolName,
            currentToolTarget: toolTarget,
            latestOutput: response,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )
    }
}
