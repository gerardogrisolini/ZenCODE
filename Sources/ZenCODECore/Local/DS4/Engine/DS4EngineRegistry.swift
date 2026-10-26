//
//  DS4EngineRegistry.swift
//  ZenCODE
//
//  Process-wide owner of the in-process DS4 engine. DS4 holds an instance
//  lock and maps tens of GiB, so at most one engine is open per process.
//
//  Semantics
//  - `engine(for:onStatus:)` returns the open engine when its identity
//    matches; concurrent requests for the same identity share one open
//    (coalescing; only the first caller's `onStatus` receives open status).
//    A failed open is not cached: the next request retries.
//  - A different identity waits for the generation lease (so the turn in
//    progress finishes), closes the open engine (every session freed, its
//    `DS4Engine` reference then throws `engineClosed`) and opens the new one.
//  - `withGenerationLease` is the FIFO generation lock: one `sync` +
//    `generate` turn at a time per process (= per engine), in arrival order,
//    cancellable while waiting (`CancellationError`). The engine for the
//    configuration is acquired under the lock, so an identity switch never
//    interrupts a turn.
//  - `withGenerationLeaseIfOpen` is the same lock for work that must not open
//    a model (the explicit checkpoint save): it runs `body` only when the
//    engine for the configuration is already open, otherwise returns `nil`.
//  - `shutdown()` closes everything without waiting for queued leases (a
//    turn in progress finishes first because engine calls are serialized on
//    the engine thread); the registry stays usable afterwards.
//  - `closeIfIdle()` closes the open engine without ever waiting. It returns
//    `false` and changes nothing while no engine is open, an open is in
//    progress, the generation lock is held, leases are queued, or a DS4
//    session is still live (another runner of this process uses the model).
//    Otherwise it takes the free lock, closes the engine and returns `true`;
//    the next `engine(for:)` reopens it.
//  - Engine lifecycle for the agent backends: closing a backend releases only
//    its DS4 sessions and the model stays loaded. The engine is closed on the
//    normal exits of `zen` (`AgentCoreSessionRunner.shutdown()`; a fatal
//    signal ends the process without it, and the OS frees the memory and the
//    instance lock), when a different DS4 model is requested (identity switch
//    above), and when a new root backend uses a non-DS4 model while no DS4
//    session is live (`AgentCoreBackend`).
//

import Foundation

actor DS4EngineRegistry {
    typealias StatusHandler = @Sendable (String) async -> Void
    /// Opens an engine (`DS4NativeEngine.open` in production, a mock in tests).
    typealias Factory = @Sendable (DS4EngineConfiguration, @escaping StatusHandler) async throws -> any DS4Engine

    static let shared = DS4EngineRegistry()

    static let nativeFactory: Factory = { configuration, onStatus in
        try await DS4NativeEngine.open(configuration: configuration, onStatus: onStatus)
    }

    private struct OpenEngine {
        let identity: String
        let engine: any DS4Engine
    }

    private struct PendingOpen {
        let token: UInt64
        let identity: String
        let task: Task<any DS4Engine, any Error>
    }

    private struct LockWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let factory: Factory
    private var current: OpenEngine?
    private var pending: PendingOpen?
    /// Bumped by `shutdown()`: an open started before it is discarded.
    private var epoch: UInt64 = 0
    private var nextToken: UInt64 = 0

    private var lockHeld = false
    private var lockWaiters: [LockWaiter] = []

    /// Session ID of the lease currently running (diagnostics).
    private(set) var activeLeaseSessionID: String?

    init(factory: @escaping Factory = DS4EngineRegistry.nativeFactory) {
        self.factory = factory
    }

    /// Identity of the open engine, if any.
    var currentIdentity: String? {
        current?.identity
    }

    /// Leases (and identity switches) waiting for the generation lock.
    var queuedLeaseCount: Int {
        lockWaiters.count
    }

    var isGenerationLockHeld: Bool {
        lockHeld
    }

    // MARK: Engines

    /// The engine for `configuration`, opening it (and closing a different
    /// one after the turn in progress) when needed.
    func engine(
        for configuration: DS4EngineConfiguration,
        onStatus: @escaping StatusHandler = { _ in }
    ) async throws -> any DS4Engine {
        let identity = configuration.identity
        if let current, current.identity == identity {
            return current.engine
        }
        if let pending, pending.identity == identity {
            return try await pending.task.value
        }
        try await acquireLock()
        defer { releaseLock() }
        return try await engineLocked(for: configuration, onStatus: onStatus)
    }

    /// Runs one generation turn: waits for the FIFO generation lock, acquires
    /// the engine for `configuration` under it, then runs `body`. Run every
    /// `sync` + `generate` (and checkpoint save/load) of a turn inside `body`.
    /// Inside `body` never request a different configuration (from this
    /// registry) nor nest another lease: both wait for this lease and deadlock.
    /// Throws `CancellationError` when cancelled while waiting, and the open
    /// errors of `engine(for:)`.
    func withGenerationLease<Value: Sendable>(
        configuration: DS4EngineConfiguration,
        sessionID: String,
        onStatus: @escaping StatusHandler = { _ in },
        _ body: @Sendable (any DS4Engine) async throws -> Value
    ) async throws -> Value {
        try await acquireLock()
        defer {
            activeLeaseSessionID = nil
            releaseLock()
        }
        let engine = try await engineLocked(for: configuration, onStatus: onStatus)
        activeLeaseSessionID = sessionID
        return try await body(engine)
    }

    /// Frees the DS4 session of `sessionID` in the open engine.
    func releaseSession(_ sessionID: String) async {
        await current?.engine.releaseSession(sessionID)
    }

    /// Like `withGenerationLease`, but only when the engine for `configuration`
    /// is already open: it never opens or replaces an engine, so a caller that
    /// merely wants to read live state (the explicit checkpoint save) cannot
    /// trigger a model load. Waits for the generation lock (a turn in progress
    /// finishes first), then re-checks the engine, and returns `nil` without
    /// running `body` when it is not open (or was replaced meanwhile).
    func withGenerationLeaseIfOpen<Value: Sendable>(
        configuration: DS4EngineConfiguration,
        sessionID: String,
        _ body: @Sendable (any DS4Engine) async throws -> Value
    ) async throws -> Value? {
        let identity = configuration.identity
        guard current?.identity == identity else {
            return nil
        }
        try await acquireLock()
        defer {
            activeLeaseSessionID = nil
            releaseLock()
        }
        guard let current, current.identity == identity else {
            return nil
        }
        activeLeaseSessionID = sessionID
        return try await body(current.engine)
    }

    /// Frees every session and closes the open engine (and one being opened).
    func shutdown() async {
        epoch &+= 1
        let engine = current?.engine
        current = nil
        let opening = pending?.task
        pending = nil
        if let engine {
            await engine.close()
        }
        // The open task sees the new epoch and closes its engine itself.
        _ = try? await opening?.value
    }

    /// Closes the open engine when nothing uses it, without waiting. Returns
    /// `true` only when this call closed it. Returns `false` and changes
    /// nothing when no engine is open, an open is in progress, the generation
    /// lock is held, leases are queued, or a DS4 session is still live.
    /// The check and the close run under the generation lock, so no lease can
    /// start on the engine meanwhile.
    func closeIfIdle() async -> Bool {
        guard current != nil, pending == nil, !lockHeld, lockWaiters.isEmpty else {
            return false
        }
        // The lock is free and nothing suspended since the checks above: take
        // it at once, so a lease arriving now queues behind this close.
        lockHeld = true
        defer { releaseLock() }
        guard let open = current, pending == nil else {
            return false
        }
        guard await open.engine.liveSessionCount() == 0 else {
            return false
        }
        // A shutdown may have closed or replaced the engine during the await.
        guard let stillOpen = current, stillOpen.engine === open.engine else {
            return false
        }
        current = nil
        await open.engine.close()
        return true
    }

    /// Called with the generation lock held.
    private func engineLocked(
        for configuration: DS4EngineConfiguration,
        onStatus: @escaping StatusHandler
    ) async throws -> any DS4Engine {
        let identity = configuration.identity
        if let current, current.identity == identity {
            return current.engine
        }
        if let pending, pending.identity == identity {
            return try await pending.task.value
        }
        if let previous = current {
            current = nil
            await previous.engine.close()
        }
        return try await startOpen(configuration, onStatus: onStatus).value
    }

    private func startOpen(
        _ configuration: DS4EngineConfiguration,
        onStatus: @escaping StatusHandler
    ) -> Task<any DS4Engine, any Error> {
        nextToken &+= 1
        let token = nextToken
        let identity = configuration.identity
        let epoch = epoch
        let factory = factory
        let task = Task<any DS4Engine, any Error> {
            do {
                let engine = try await factory(configuration, onStatus)
                try await self.finishOpen(token: token, identity: identity, epoch: epoch, engine: engine)
                return engine
            } catch {
                self.clearPending(token: token)
                throw error
            }
        }
        pending = PendingOpen(token: token, identity: identity, task: task)
        return task
    }

    private func finishOpen(token: UInt64, identity: String, epoch: UInt64, engine: any DS4Engine) async throws {
        clearPending(token: token)
        guard epoch == self.epoch else {
            await engine.close()
            throw DS4EngineError.engineClosed
        }
        current = OpenEngine(identity: identity, engine: engine)
    }

    private func clearPending(token: UInt64) {
        if pending?.token == token {
            pending = nil
        }
    }

    // MARK: FIFO generation lock

    private func acquireLock() async throws {
        try Task.checkCancellation()
        if !lockHeld {
            lockHeld = true
            return
        }
        nextToken &+= 1
        let id = nextToken
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    lockWaiters.append(LockWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Hands the lock to the next waiter (ownership transfer) or frees it.
    private func releaseLock() {
        if lockWaiters.isEmpty {
            lockHeld = false
        } else {
            lockWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        guard let index = lockWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        lockWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
