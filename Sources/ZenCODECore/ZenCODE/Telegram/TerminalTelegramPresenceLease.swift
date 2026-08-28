//
//  TerminalTelegramPresenceLease.swift
//  ZenCODE
//

import Foundation

/// Lifecycle-safe `sendChatAction` presence lease.
///
/// Telegram's typing indicator lives for about 5 seconds; a turn can run far
/// longer. Without renewal the indicator dies mid-turn and the operator thinks
/// the session hung; without lifecycle safety a renewal loop outlives a stop()
/// or teardown and keeps a dead session "typing" forever.
///
/// A lease solves both: an owning scope takes the lease out, a renewal task
/// refreshes `sendChatAction` every refresh interval while the lease is current,
/// and releasing (or replacing) the lease fences the renewal task through a
/// monotonically increasing generation, exactly like the polling generation in
/// ``TerminalTelegramControlService``. A renewal that resumes after release,
/// after replacement, or after `stop()` finds a stale generation and exits
/// without touching the wire or the state.
public actor TerminalTelegramPresenceLeaseManager {
    /// `sendChatAction` statuses live about 5 seconds; refresh well before
    /// expiry so the indicator never flickers off between renewals.
    static let refreshInterval: Duration = .seconds(4)

    /// One held presence lease.
    public struct Lease: Sendable, Equatable {
        /// Scope the lease was taken for.
        public let scope: TerminalTelegramPresenceScope
        /// Generation at issue time; a renewal may run only while this is still
        /// the manager's current generation.
        public let generation: Int

        init(scope: TerminalTelegramPresenceScope, generation: Int) {
            self.scope = scope
            self.generation = generation
        }
    }

    private var generation = 0
    private var current: Lease?
    private var currentFence: TerminalTelegramWireFence?
    /// Sends one chat action. Injected so tests never touch the network.
    private let sendAction: @Sendable (TerminalTelegramPresenceScope) async -> Void

    init(sendAction: @escaping @Sendable (TerminalTelegramPresenceScope) async -> Void) {
        self.sendAction = sendAction
    }

    /// Takes (or replaces) the lease for `scope` and starts renewal.
    ///
    /// Taking a new lease while one is held replaces it atomically: the old
    /// renewal loop fences out at its next wake-up, so two turns can never
    /// both be "typing" for the same session. The `scope` in the replacement
    /// decides the chat-action audience.
    public func acquire(
        scope: TerminalTelegramPresenceScope,
        fence: TerminalTelegramWireFence
    ) async -> Lease {
        generation += 1
        let lease = Lease(scope: scope, generation: generation)
        current = lease
        currentFence = fence
        await sendAndScheduleRenewal(for: lease, fence: fence)
        return lease
    }

    /// Releases the held lease and fences renewals. Releasing an unheld or
    /// already-replaced lease is a no-op: a generation mismatch makes the call
    /// inert by construction.
    public func release(_ lease: Lease) {
        guard current == lease else { return }
        generation += 1
        current = nil
        currentFence = nil
    }

    /// Whether the lease is still the current one.
    public func isActive(_ lease: Lease) -> Bool {
        current == lease
    }

    /// The lease currently held, if any.
    public var heldLease: Lease? {
        current
    }

    func currentFence(for scope: TerminalTelegramPresenceScope) -> TerminalTelegramWireFence? {
        guard current?.scope == scope else { return nil }
        return currentFence
    }

    /// Releases any held lease; used at stop()/teardown.
    public func releaseAll() {
        guard current != nil else { return }
        generation += 1
        current = nil
        currentFence = nil
    }

    private func sendAndScheduleRenewal(
        for lease: Lease,
        fence: TerminalTelegramWireFence
    ) async {
        // First emission fires immediately so presence starts with the turn.
        await sendIfCurrent(lease, fence: fence)
        let task = Task(name: "ZenCODE.Telegram.presence-renewal") { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.refreshInterval)
                } catch {
                    return
                }
                guard let self else { return }
                // Fenced-out renewals exit before touching the wire.
                guard await self.isCurrent(lease, fence: fence) else { return }
                await self.sendIfCurrent(lease, fence: fence)
            }
        }
        _ = task
    }

    private func isCurrent(
        _ lease: Lease,
        fence: TerminalTelegramWireFence
    ) -> Bool {
        current == lease && currentFence === fence
    }

    private func sendIfCurrent(
        _ lease: Lease,
        fence: TerminalTelegramWireFence
    ) async {
        guard isCurrent(lease, fence: fence),
              (try? await fence.validate(
                chatID: lease.scope.chatID,
                topicID: lease.scope.topicID
              )) != nil,
              isCurrent(lease, fence: fence) else { return }
        await sendAction(lease.scope)
    }
}

/// Audience of one presence lease: which remote surface is being told that
/// ZenCODE is working, and why.
public enum TerminalTelegramPresenceScope: Sendable, Equatable {
    /// A generation turn is running for the linked chat/topic.
    case turn(chatID: Int64, topicID: Int? = nil)
    /// A voice note is being downloaded and transcribed.
    case transcription(chatID: Int64, topicID: Int? = nil)

    public var chatID: Int64 {
        switch self {
        case let .turn(chatID, _), let .transcription(chatID, _):
            return chatID
        }
    }

    public var topicID: Int? {
        switch self {
        case let .turn(_, topicID), let .transcription(_, topicID):
            return topicID
        }
    }
}
