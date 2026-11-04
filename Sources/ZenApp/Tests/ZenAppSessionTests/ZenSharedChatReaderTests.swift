//
//  ZenSharedChatReaderTests.swift
//  ZenAppSessionTests
//
//  The shared-chat reader without a window (the bound, the unread messages,
//  the selection, the header), and the observation supervisor over a real
//  coordinator (the recovery, its backoff, the room change, the stop, and the
//  chain of its busy declarations and operations).
//

import Foundation
import Synchronization
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

// MARK: - Fixtures

/// A real room bus, its messages sent through the public API: an agent's
/// with `send`, the operator's through the bridge of a sub-agent runtime.
private struct ZenRoomFixture {
    static let roomID = "zen-reader-room"
    static let agentID = "agent-1"

    let runtime = DirectSubAgentRuntime(backendFactory: { ZenScriptedBackend() }, profileResolver: { _ in nil })

    func setUp() async throws -> AgentSharedChat {
        let chat = await runtime.sharedChat
        try await chat.registerCoordinator(roomID: Self.roomID)
        try await chat.registerAgent(id: Self.agentID, name: "Worker", roomID: Self.roomID)
        return chat
    }

    /// `count` messages of the agent for the operator.
    func agentMessages(_ count: Int, prefix: String = "Agent") async throws -> [AgentSharedChat.Message] {
        let chat = try await setUp()
        var messages: [AgentSharedChat.Message] = []
        for index in 0..<count {
            let delivery = try await chat.send(
                roomID: Self.roomID,
                senderID: Self.agentID,
                destination: .operator,
                text: "\(prefix) \(index)"
            )
            messages.append(delivery.message)
        }
        return messages
    }

    func operatorMessage(_ text: String) async throws -> AgentSharedChat.Message {
        _ = try await setUp()
        return try await runtime.sendSharedChatMessage(
            text: text,
            destination: .coordinator,
            rootSessionID: Self.roomID
        ).message
    }
}

// MARK: - Reader

@Suite
struct ZenSharedChatReaderTests {
    @Test("Messages are kept once per id, and append returns only the new ones")
    func deduplicates() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(3)
        var reader = ZenSharedChatReader()
        #expect(reader.append(Array(messages.prefix(2))).map(\.id) == messages.prefix(2).map(\.id))
        #expect(reader.append([messages[1], messages[2], messages[2]]).map(\.id) == [messages[2].id])
        #expect(reader.append(messages).isEmpty)
        #expect(reader.messages.map(\.id) == messages.map(\.id))
        #expect(reader.unreadCount == 3)
    }

    @Test("The history is bounded at the room's bound, the oldest evicted first")
    func isBounded() async throws {
        let fixture = ZenRoomFixture()
        let overflow = 5
        let messages = try await fixture.agentMessages(ZenSharedChatReader.capacity + overflow)
        var reader = ZenSharedChatReader()
        let retained = reader.append(messages)
        #expect(ZenSharedChatReader.capacity == AgentSharedChat.maximumRetainedMessagesPerRoom)
        #expect(reader.messages.count == ZenSharedChatReader.capacity)
        #expect(reader.messages.first?.id == messages[overflow].id)
        #expect(reader.messages.last?.id == messages.last?.id)
        #expect(retained.map(\.id) == messages.dropFirst(overflow).map(\.id))
        #expect(reader.unreadCount == ZenSharedChatReader.capacity)
        #expect(!reader.isUnread(messages[0].id))
        // An evicted message comes back as a new one.
        #expect(reader.append([messages[0]]).map(\.id) == [messages[0].id])
        #expect(reader.messages.count == ZenSharedChatReader.capacity)
    }

    @Test("The operator's messages are kept but never unread")
    func operatorMessagesAreRead() async throws {
        let fixture = ZenRoomFixture()
        let agent = try await fixture.agentMessages(2)
        let mine = try await fixture.operatorMessage("Mine")
        var reader = ZenSharedChatReader()
        reader.append([agent[0], mine, agent[1]])
        #expect(reader.messages.count == 3)
        #expect(reader.unreadCount == 2)
        #expect(!reader.isUnread(mine.id))
        #expect(reader.isUnread(agent[0].id))
        #expect(reader.isPresented)

        var onlyMine = ZenSharedChatReader()
        onlyMine.append([mine])
        #expect(onlyMine.unreadCount == 0)
        #expect(!onlyMine.isPresented)
    }

    @Test("Opening shows the first unread message; navigation reads up to the selection, never back")
    func openAndNavigate() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(4)
        var reader = ZenSharedChatReader()
        reader.append(Array(messages.prefix(2)))
        // Read the first two, then two more arrive.
        reader.openReader()
        reader.navigate(.next)
        reader.closeReader()
        #expect(reader.unreadCount == 0)
        reader.append(Array(messages.suffix(2)))
        #expect(reader.unreadCount == 2)

        reader.openReader()
        #expect(reader.isReaderOpen)
        #expect(reader.selectedMessageID == messages[2].id)
        #expect(reader.selectedIndex == 2)
        #expect(reader.selectedMessage?.text == "Agent 2")
        #expect(!reader.isUnread(messages[2].id))
        #expect(reader.isUnread(messages[3].id))
        #expect(reader.unreadCount == 1)

        // Back: nothing becomes unread; the first clamps.
        reader.navigate(.previous)
        #expect(reader.selectedIndex == 1)
        reader.navigate(.first)
        reader.navigate(.previous)
        #expect(reader.selectedIndex == 0)
        #expect(reader.unreadCount == 1)

        // The last clamps and reads everything up to it.
        reader.navigate(.last)
        reader.navigate(.next)
        #expect(reader.selectedIndex == 3)
        #expect(reader.unreadCount == 0)

        reader.closeReader()
        #expect(!reader.isReaderOpen)
        #expect(reader.selectedMessageID == nil)
        #expect(reader.selectedIndex == nil)
        // Closed, navigation does nothing.
        reader.navigate(.first)
        #expect(reader.selectedMessageID == nil)

        // With nothing unread, opening shows the newest.
        reader.openReader()
        #expect(reader.selectedIndex == 3)
    }

    @Test("Selecting an unread message reads every message before it")
    func navigationReadsThroughTheSelection() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(4)
        var reader = ZenSharedChatReader()
        reader.append(messages)
        reader.openReader()
        #expect(reader.selectedIndex == 0)
        #expect(reader.unreadCount == 3)
        reader.navigate(.last)
        #expect(reader.unreadCount == 0)
        #expect(messages.allSatisfy { !reader.isUnread($0.id) })
    }

    @Test("Arrivals keep the selection of an open reader; an evicted selection moves to the newest, all read")
    func arrivalsWhileOpen() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(ZenSharedChatReader.capacity + 2)
        var reader = ZenSharedChatReader()
        reader.append([messages[0], messages[1]])
        reader.openReader()
        #expect(reader.selectedMessageID == messages[0].id)

        reader.append([messages[2]])
        #expect(reader.selectedMessageID == messages[0].id)
        #expect(reader.isUnread(messages[2].id))
        #expect(reader.unreadCount == 2)

        // The selected message falls out of the history.
        reader.append(Array(messages.dropFirst(3)))
        #expect(reader.messages.first?.id != messages[0].id)
        #expect(reader.selectedMessageID == messages.last?.id)
        #expect(reader.unreadCount == 0)

        // An open reader on nothing selects the first arrival, read.
        var empty = ZenSharedChatReader()
        empty.openReader()
        #expect(empty.selectedMessageID == nil)
        empty.append([messages[0]])
        #expect(empty.selectedMessageID == messages[0].id)
        #expect(empty.unreadCount == 0)
    }

    @Test("The header has the terminal's texts")
    func headerTexts() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(3)
        var reader = ZenSharedChatReader()
        #expect(reader.headerText == "Chat · 0 messages · 0 new")
        #expect(!reader.isPresented)
        reader.openReader()
        #expect(reader.headerText == "Chat · 0 messages")
        #expect(reader.isPresented)
        reader.closeReader()

        reader.append([messages[0]])
        #expect(reader.headerText == "Chat · 1 message · 1 new")
        reader.append(Array(messages.suffix(2)))
        #expect(reader.headerText == "Chat · 3 messages · 3 new")
        reader.openReader()
        #expect(reader.headerText == "Chat · 1/3 · 2 new")
        reader.navigate(.next)
        #expect(reader.headerText == "Chat · 2/3 · 1 new")
        reader.closeReader()
        #expect(reader.headerText == "Chat · 3 messages · 1 new")
        #expect(reader.isPresented)
    }

    @Test("Presented while open or while something is unread; reset forgets everything")
    func presentationAndReset() async throws {
        let fixture = ZenRoomFixture()
        let messages = try await fixture.agentMessages(1)
        var reader = ZenSharedChatReader()
        reader.append(messages)
        #expect(reader.isPresented)
        reader.openReader()
        #expect(reader.unreadCount == 0)
        #expect(reader.isPresented)
        reader.closeReader()
        #expect(!reader.isPresented)

        reader.openReader()
        reader.reset()
        #expect(reader == ZenSharedChatReader())
        #expect(reader.messages.isEmpty)
        #expect(!reader.isReaderOpen)
        // A reset reader takes the same messages again.
        #expect(reader.append(messages).count == 1)
    }
}

// MARK: - Observation supervisor

/// What the supervisor did, recorded by its environment.
private final class ZenObservationLog: Sendable {
    private let state = Mutex<(backoffs: [Int], busy: [Bool], detached: Int)>(([], [], 0))

    var backoffs: [Int] { state.withLock { $0.backoffs } }
    var busy: [Bool] { state.withLock { $0.busy } }
    var detached: Int { state.withLock { $0.detached } }

    func backoff(_ attempt: Int) { state.withLock { $0.backoffs.append(attempt) } }
    func declare(_ isBusy: Bool) { state.withLock { $0.busy.append(isBusy) } }
    func detach() { state.withLock { $0.detached += 1 } }
}

/// What the window answers the supervisor, changed by the test.
@MainActor
private final class ZenObservationSwitches {
    var mayRecover = true
    var isBusy = true
}

/// The calls of the chain a fake environment received, in the order they
/// reached it: the busy declarations and the operations run on the chain.
private final class ZenChainLog: Sendable {
    enum Entry: Equatable, Sendable {
        case busy(Bool)
        case operation(String)
    }

    private let state = Mutex<[Entry]>([])

    var entries: [Entry] { state.withLock { $0 } }

    func append(_ entry: Entry) { state.withLock { $0.append(entry) } }
}

/// Set by a test task on the main actor in the same step as its call of
/// ``ZenSharedChatObservation/serialized(_:)``, which takes its place on
/// the chain before it suspends: once set, the place is taken.
@MainActor
private final class ZenCallMark {
    private(set) var isCalled = false

    func mark() { isCalled = true }
}

@MainActor
@Suite(.serialized)
struct ZenSharedChatObservationTests {
    private static func coordinator() -> AgentSharedChatCoordinator {
        AgentSharedChatCoordinator(source: AgentSharedChatCoordinator.Source(
            drainCoordinatorMessages: { _ in [] },
            participants: { _ in [] },
            allRoomMessages: { _ in [] }
        ))
    }

    private static func supervisor(
        _ coordinator: AgentSharedChatCoordinator,
        log: ZenObservationLog
    ) -> ZenSharedChatObservation {
        ZenSharedChatObservation(environment: ZenSharedChatObservation.Environment(
            attach: { roomID in await coordinator.observeSubscription(roomID: roomID) },
            detach: { observation in
                log.detach()
                await coordinator.detach(observation)
            },
            setConsumerBusy: { isBusy, observation in
                log.declare(isBusy)
                await coordinator.setConsumerBusy(isBusy, observation: observation)
            },
            backoff: { attempt in log.backoff(attempt) }
        ))
    }

    @Test("The backoff paces like the terminal's: 50 ms, doubling, within 2 s")
    func backoffPacing() {
        let delays = (1...8).map(ZenSharedChatObservation.Environment.backoffMilliseconds(attempt:))
        #expect(delays == [50, 100, 200, 400, 800, 1_600, 1_600, 1_600])
        #expect(delays.allSatisfy { $0 <= 2_000 })
    }

    @Test("A stream that ends on its own is replaced, with a backoff while none delivers; a room change and a stop retire it")
    func recoveryAndStop() async throws {
        let coordinator = Self.coordinator()
        let log = ZenObservationLog()
        let supervisor = Self.supervisor(coordinator, log: log)
        let switches = ZenObservationSwitches()
        supervisor.handlers = ZenSharedChatObservation.Handlers(
            consumerIsBusy: { switches.isBusy },
            didAttach: { _ in },
            handle: { _, _ in },
            mayRecover: { _ in switches.mayRecover }
        )

        await supervisor.follow(roomID: "room-a")
        let first = try #require(supervisor.observation)
        #expect(supervisor.roomID == "room-a")
        #expect(supervisor.attachCount == 1)
        // The busy state is declared right after the attach.
        await supervisor.flushConsumerBusy()
        #expect(log.busy == [true])
        // The same room again: nothing.
        await supervisor.follow(roomID: "room-a")
        #expect(supervisor.attachCount == 1)

        // Ended twice without an event: two replacements, each after a
        // longer backoff.
        await coordinator.stop(roomID: "room-a")
        await waitUntil("the first replacement") { supervisor.recoveryCount == 1 && supervisor.observation != nil }
        #expect(supervisor.observation?.id != first.id)
        await coordinator.stop(roomID: "room-a")
        await waitUntil("the second replacement") { supervisor.recoveryCount == 2 && supervisor.observation != nil }
        #expect(log.backoffs == [1, 2])
        #expect(supervisor.attachCount == 3)
        #expect(supervisor.detachCount == 2)
        // Every replacement declares the busy state again.
        await supervisor.flushConsumerBusy()
        #expect(log.busy == [true, true, true])

        // A room change detaches the old observation before the new one.
        let beforeChange = try #require(supervisor.observation)
        switches.isBusy = false
        await supervisor.follow(roomID: "room-b")
        #expect(supervisor.roomID == "room-b")
        #expect(supervisor.attachCount == 4)
        #expect(supervisor.observation?.roomID == "room-b")
        #expect(!supervisor.isCurrent(beforeChange))
        await waitUntil("the old room detached") { log.detached == 3 }

        // A stream ending when the window does not allow it is not replaced.
        switches.mayRecover = false
        await coordinator.stop(roomID: "room-b")
        await waitUntil("the ended stream detached") { log.detached == 4 }
        #expect(supervisor.observation == nil)
        #expect(supervisor.recoveryCount == 2)

        // A stop retires the supervisor for good.
        switches.mayRecover = true
        await supervisor.follow(roomID: "room-c")
        #expect(supervisor.observation != nil)
        let detach = supervisor.stop()
        #expect(supervisor.observation == nil)
        #expect(supervisor.isStopped)
        await detach?.value
        #expect(log.detached == 5)
        await supervisor.follow(roomID: "room-d")
        #expect(supervisor.observation == nil)
        #expect(supervisor.declareConsumerBusy(true) == nil)
        #expect(supervisor.attachCount == 5)
        await coordinator.stopAll()
    }

    @Test("Busy declarations reach the Core in order, on the current observation only")
    func busyDeclarationsAreSerial() async throws {
        let coordinator = Self.coordinator()
        let log = ZenObservationLog()
        let supervisor = Self.supervisor(coordinator, log: log)
        #expect(supervisor.declareConsumerBusy(true) == nil)
        supervisor.handlers = ZenSharedChatObservation.Handlers(
            consumerIsBusy: { false },
            didAttach: { _ in },
            handle: { _, _ in },
            mayRecover: { _ in false }
        )
        await supervisor.follow(roomID: "room-a")
        for value in [true, false, true, true, false] {
            supervisor.declareConsumerBusy(value)
        }
        await supervisor.flushConsumerBusy()
        #expect(log.busy == [false, true, false, true, true, false])
        await supervisor.stop()?.value
        await coordinator.stopAll()
    }

    /// A supervisor whose environment records the chain in `log`; every busy
    /// declaration of `true` waits at `hold` once recorded, so the test can
    /// keep the chain waiting.
    private static func chainSupervisor(
        _ coordinator: AgentSharedChatCoordinator,
        log: ZenChainLog,
        hold: ZenGate
    ) -> ZenSharedChatObservation {
        let supervisor = ZenSharedChatObservation(environment: ZenSharedChatObservation.Environment(
            attach: { roomID in await coordinator.observeSubscription(roomID: roomID) },
            detach: { observation in await coordinator.detach(observation) },
            setConsumerBusy: { isBusy, _ in
                log.append(.busy(isBusy))
                if isBusy {
                    await hold.pass()
                }
            },
            backoff: { _ in }
        ))
        supervisor.handlers = ZenSharedChatObservation.Handlers(
            consumerIsBusy: { false },
            didAttach: { _ in },
            handle: { _, _ in },
            mayRecover: { _ in false }
        )
        return supervisor
    }

    @Test("An operation on the chain lands after the declarations made before it and before those made after it, and returns its result")
    func serializedKeepsItsPlace() async throws {
        let coordinator = Self.coordinator()
        let log = ZenChainLog()
        let hold = ZenGate()
        let supervisor = Self.chainSupervisor(coordinator, log: log, hold: hold)
        await supervisor.follow(roomID: "room-a")
        await supervisor.flushConsumerBusy()
        #expect(log.entries == [.busy(false)])

        // A declaration the Core holds keeps the chain waiting.
        supervisor.declareConsumerBusy(true)
        await waitUntil("the declaration reaches the Core") { await hold.reached }
        let mark = ZenCallMark()
        let inside = ZenGate()
        let operation = Task { @MainActor in
            mark.mark()
            return await supervisor.serialized {
                log.append(.operation("claim"))
                await inside.pass()
                return 42
            }
        }
        await waitUntil("the operation takes its place") { mark.isCalled }
        // Made after the call, while the operation still waits.
        supervisor.declareConsumerBusy(false)
        #expect(log.entries == [.busy(false), .busy(true)])

        // The operation runs once the held declaration ended, and the later
        // declaration waits for it to return.
        await hold.open()
        await waitUntil("the operation runs") { await inside.reached }
        #expect(log.entries == [.busy(false), .busy(true), .operation("claim")])
        await inside.open()
        #expect(await operation.value == 42)
        await supervisor.flushConsumerBusy()
        #expect(log.entries == [.busy(false), .busy(true), .operation("claim"), .busy(false)])
        await supervisor.stop()?.value
        await coordinator.stopAll()
    }

    @Test("An operation on the chain runs with no observation attached, and after a stop, still in its place")
    func serializedRunsWithoutAnObservation() async throws {
        let coordinator = Self.coordinator()
        let log = ZenChainLog()
        let hold = ZenGate()
        let supervisor = Self.chainSupervisor(coordinator, log: log, hold: hold)

        // Nothing attached yet: no declaration is made, the operation runs.
        #expect(supervisor.declareConsumerBusy(true) == nil)
        let unattached = await supervisor.serialized {
            log.append(.operation("unattached"))
            return "answered"
        }
        #expect(unattached == "answered")
        #expect(log.entries == [.operation("unattached")])

        // A declaration the Core holds, then a stop: nothing is declared any
        // more, but an operation still runs, behind the held declaration.
        await supervisor.follow(roomID: "room-a")
        supervisor.declareConsumerBusy(true)
        await waitUntil("the declaration reaches the Core") { await hold.reached }
        await supervisor.stop()?.value
        #expect(supervisor.observation == nil)
        #expect(supervisor.declareConsumerBusy(false) == nil)
        let mark = ZenCallMark()
        let operation = Task { @MainActor in
            mark.mark()
            return await supervisor.serialized {
                log.append(.operation("stopped"))
                return 7
            }
        }
        await waitUntil("the operation takes its place") { mark.isCalled }
        #expect(log.entries == [.operation("unattached"), .busy(false), .busy(true)])

        await hold.open()
        #expect(await operation.value == 7)
        #expect(log.entries == [.operation("unattached"), .busy(false), .busy(true), .operation("stopped")])
        await coordinator.stopAll()
    }
}
