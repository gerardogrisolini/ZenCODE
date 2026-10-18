//
//  TerminalTelegramBotDispatcher.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Process-wide owner of Bot API polling and persisted offsets.
///
/// There is exactly one long poll for a bot id. Every active terminal service
/// receives a broadcast copy of each update and applies its own route/room ACL;
/// therefore one session can never acknowledge and discard another session's
/// update before that session sees it.
actor TerminalTelegramBotDispatcher {
    static let shared = TerminalTelegramBotDispatcher()

    struct Subscription: Sendable {
        let id: UUID
        let botID: Int64
        let updates: AsyncStream<TerminalTelegramUpdate>
    }

    /// Receives the latest polling failure (`nil` once a poll succeeds again).
    /// Invoked only on changes, in order, from a per-subscription consumer task:
    /// a slow sink never blocks the poll loop or the dispatcher actor.
    typealias PollStatusSink = @Sendable (TerminalTelegramPollFailure?) async -> Void
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    private struct BotState {
        var subscribers: [UUID: AsyncStream<TerminalTelegramUpdate>.Continuation]
        /// Ordered, unbounded mailbox per subscription feeding its sink's
        /// consumer task. Finishing it ends that task after it drains.
        var statusChannels: [UUID: AsyncStream<TerminalTelegramPollFailure?>.Continuation] = [:]
        var pollError: TerminalTelegramPollFailure?
        var task: Task<Void, Never>?
        var taskID: UUID?
        var generation: UUID
        var nextOffset: Int?
        let client: TerminalTelegramAPIClient
    }

    private var bots: [Int64: BotState] = [:]
    /// Poll tasks cancelled because their bot lost its last subscriber, keyed
    /// by task id until `pollingDidFinish` runs. The public `unsubscribe`
    /// awaits them so a following subscribe cannot start a second `getUpdates`
    /// while the old long poll is still in flight (HTTP 409).
    private var retiringPolls: [UUID: (botID: Int64, task: Task<Void, Never>)] = [:]
    private let sleeper: Sleeper
    private let jitter: @Sendable () -> Double

    init(
        sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.sleeper = sleeper
        self.jitter = jitter
    }

    func subscribe(
        botID: Int64,
        client: TerminalTelegramAPIClient,
        pollStatus: PollStatusSink? = nil
    ) async throws -> Subscription {
        let id = UUID()
        var continuation: AsyncStream<TerminalTelegramUpdate>.Continuation!
        let stream = AsyncStream<TerminalTelegramUpdate>(bufferingPolicy: .bufferingOldest(64)) {
            continuation = $0
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(botID: botID, subscriptionID: id) }
        }

        if bots[botID] == nil {
            let last = try TerminalTelegramUpdateOffsetStore.loadRequired(botID: botID)
            bots[botID] = BotState(
                subscribers: [:], task: nil, taskID: nil, generation: UUID(),
                nextOffset: last.map { $0 + 1 }, client: client
            )
        }
        bots[botID]?.subscribers[id] = continuation
        if let pollStatus {
            let (statusStream, statusContinuation) = AsyncStream<TerminalTelegramPollFailure?>
                .makeStream(bufferingPolicy: .unbounded)
            Task(name: "ZenCODE.Telegram.poll-status.\(botID)") {
                for await failure in statusStream {
                    await pollStatus(failure)
                }
            }
            // A late subscriber hears the current failure first; it is queued
            // before any later change because both happen on this actor.
            if let current = bots[botID]?.pollError {
                statusContinuation.yield(current)
            }
            bots[botID]?.statusChannels[id] = statusContinuation
        }
        startPollingIfNeeded(botID: botID)
        return Subscription(id: id, botID: botID, updates: stream)
    }

    /// Removes the subscription. When it was the last one, the poll task is
    /// cancelled and this call returns only after that task (and its in-flight
    /// `getUpdates`) has terminated. Awaiting here is deadlock-free: while
    /// suspended the actor is free, so the poll task's own calls back into it
    /// (`publish`, `setPollError`, `pollingDidFinish`) can run.
    func unsubscribe(_ subscription: Subscription) async {
        unsubscribe(botID: subscription.botID, subscriptionID: subscription.id)
        // Also covers the race where the stream's `onTermination` already
        // removed this subscription and retired the poll task.
        let retiring = retiringPolls.values
            .filter { $0.botID == subscription.botID }
            .map(\.task)
        for task in retiring {
            await task.value
        }
    }

    private func unsubscribe(botID: Int64, subscriptionID: UUID) {
        guard var state = bots[botID] else { return }
        state.subscribers.removeValue(forKey: subscriptionID)?.finish()
        state.statusChannels.removeValue(forKey: subscriptionID)?.finish()
        guard state.subscribers.isEmpty else {
            bots[botID] = state
            return
        }
        retire(botID: botID, state: state)
    }

    /// Drops the bot state, cancelling its poll task and remembering it in
    /// ``retiringPolls`` until it finishes.
    private func retire(botID: Int64, state: BotState) {
        if let task = state.task, let taskID = state.taskID {
            task.cancel()
            retiringPolls[taskID] = (botID, task)
        }
        for channel in state.statusChannels.values { channel.finish() }
        bots.removeValue(forKey: botID)
    }

    private func poll(
        botID: Int64,
        generation: UUID,
        taskID: UUID,
        initialOffset: Int?,
        client: TerminalTelegramAPIClient
    ) async {
        defer { pollingDidFinish(botID: botID, generation: generation, taskID: taskID) }
        var offset = initialOffset
        var backoff = TerminalTelegramPollBackoff()
        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(offset: offset, timeout: 30)
                backoff.recordSuccess()
                setPollError(nil, botID: botID, generation: generation)
                for update in updates {
                    guard await publish(update, botID: botID, generation: generation) else {
                        return
                    }
                    offset = update.updateID + 1
                }
            } catch is CancellationError {
                return
            } catch {
                let decision = backoff.recordFailure(error, jitter: jitter())
                let description = TerminalTelegramPollBackoff.sanitizedDescription(error)
                if decision.kind.isPersistent {
                    ZenLogger.warning(
                        .diagnostics,
                        "Telegram getUpdates failing (\(decision.kind)); retrying in \(decision.delay): \(description)"
                    )
                }
                setPollError(
                    TerminalTelegramPollFailure(
                        text: "Telegram polling failed: \(description)",
                        isPersistent: decision.kind.isPersistent
                    ),
                    botID: botID, generation: generation
                )
                do {
                    try await sleeper(decision.delay)
                } catch {
                    return
                }
            }
        }
    }

    /// Records the polling status for the bot and, when it changes, enqueues it
    /// on every subscription's status channel. Never suspends: sinks run on
    /// their own consumer tasks, so the poll loop is not blocked by them.
    private func setPollError(
        _ failure: TerminalTelegramPollFailure?, botID: Int64, generation: UUID
    ) {
        guard var state = bots[botID], state.generation == generation,
              state.pollError != failure else { return }
        state.pollError = failure
        bots[botID] = state
        for channel in state.statusChannels.values {
            channel.yield(failure)
        }
    }

    /// Admits to every live subscriber before persisting.  Persisting first would
    /// lose an update if any bounded subscriber dropped it or terminated between
    /// the write and broadcast.
    private func publish(
        _ update: TerminalTelegramUpdate,
        botID: Int64,
        generation: UUID
    ) async -> Bool {
        var admittedSubscriberIDs: Set<UUID> = []
        while true {
            guard let state = bots[botID], state.generation == generation,
                  !state.subscribers.isEmpty else { return false }
            // Re-read after every suspension. A subscribe that linearizes while
            // an older subscriber is applying backpressure must receive this
            // update before its offset can be persisted.
            let pending = state.subscribers.filter { !admittedSubscriberIDs.contains($0.key) }
            guard !pending.isEmpty else { break }
            for (id, continuation) in pending {
                admission: while true {
                    guard bots[botID]?.generation == generation,
                          bots[botID]?.subscribers[id] != nil else { break admission }
                    switch continuation.yield(update) {
                    case .enqueued:
                        admittedSubscriberIDs.insert(id)
                        break admission
                    case .terminated:
                        removeSubscriber(botID: botID, subscriptionID: id, generation: generation)
                        break admission
                    case .dropped:
                        await Task.yield()
                        guard !Task.isCancelled else { return false }
                    @unknown default:
                        return false
                    }
                }
            }
        }
        guard let liveState = bots[botID], liveState.generation == generation else {
            return false
        }
        guard !liveState.subscribers.isEmpty else {
            retire(botID: botID, state: liveState)
            return false
        }
        do {
            try TerminalTelegramUpdateOffsetStore.save(updateID: update.updateID, botID: botID)
        } catch {
            for continuation in liveState.subscribers.values { continuation.finish() }
            retire(botID: botID, state: liveState)
            return false
        }
        bots[botID]?.nextOffset = update.updateID + 1
        return true
    }

    private func removeSubscriber(botID: Int64, subscriptionID: UUID, generation: UUID) {
        guard var state = bots[botID], state.generation == generation else { return }
        state.subscribers.removeValue(forKey: subscriptionID)
        state.statusChannels.removeValue(forKey: subscriptionID)?.finish()
        bots[botID] = state
    }

    private func startPollingIfNeeded(botID: Int64) {
        guard var state = bots[botID], state.task == nil, !state.subscribers.isEmpty else { return }
        let taskID = UUID()
        let generation = state.generation
        let offset = state.nextOffset
        let client = state.client
        state.taskID = taskID
        state.task = Task(name: "ZenCODE.Telegram.bot-dispatcher.\(botID)") { [weak self] in
            await self?.poll(
                botID: botID, generation: generation, taskID: taskID,
                initialOffset: offset, client: client
            )
        }
        bots[botID] = state
    }

    private func pollingDidFinish(botID: Int64, generation: UUID, taskID: UUID) {
        retiringPolls.removeValue(forKey: taskID)
        guard var state = bots[botID], state.generation == generation,
              state.taskID == taskID else { return }
        state.task = nil
        state.taskID = nil
        bots[botID] = state
        // A cancellation/error can race a new subscribe. If that subscribe has
        // already linearized, immediately replace the completed owner task.
        startPollingIfNeeded(botID: botID)
    }
}
