//
//  TerminalVoiceTranscriptionRegistry.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Owns the in-flight voice transcription tasks started by remote (Telegram)
/// messages.
///
/// Remote transcriptions used to be started as fire-and-forget `Task`s that
/// captured `TerminalChat`. Nothing owned them, so they could not be cancelled,
/// they kept the chat alive past teardown, and an operator could start an
/// unbounded number of concurrent downloads plus transcriptions by sending voice
/// notes in a burst.
///
/// The registry gives those tasks an owner: the interactive runtime loop holds
/// it, `cancelAll()` runs at teardown, finished tasks are evicted, and
/// ``maximumConcurrentTranscriptions`` bounds how many may run at once so a
/// burst is rejected with a user-visible message instead of piling up.
final class TerminalVoiceTranscriptionRegistry: Sendable {
    /// Upper bound on concurrent remote transcriptions.
    static let maximumConcurrentTranscriptions = 3

    private struct State {
        var tasks: [UUID: Task<Void, Never>] = [:]
        var isShutDown = false
    }

    private let state = Mutex(State())

    init() {}

    var activeCount: Int {
        state.withLock { $0.tasks.count }
    }

    var isShutDown: Bool {
        state.withLock { $0.isShutDown }
    }

    /// Reserves a slot for a new transcription. Returns `nil` when the registry
    /// is shut down or already at capacity.
    func reserveSlot() -> UUID? {
        state.withLock { state -> UUID? in
            guard !state.isShutDown,
                  state.tasks.count < Self.maximumConcurrentTranscriptions else {
                return nil
            }
            let id = UUID()
            // Placeholder claim so a concurrent reservation cannot exceed the
            // bound between reserving and registering the task.
            state.tasks[id] = Task(name: "ZenCODE.Telegram.transcription-slot") {}
            return id
        }
    }

    /// Attaches the running task to a previously reserved slot. If the registry
    /// was shut down in between, the task is cancelled immediately.
    func register(_ task: Task<Void, Never>, for id: UUID) {
        let shouldCancel = state.withLock { state -> Bool in
            guard !state.isShutDown, state.tasks[id] != nil else {
                return true
            }
            state.tasks[id] = task
            return false
        }
        if shouldCancel {
            task.cancel()
        }
    }

    /// Releases a slot once its transcription has finished or been cancelled.
    func release(_ id: UUID) {
        state.withLock { state in
            state.tasks[id] = nil
        }
    }

    /// Cancels every in-flight transcription and refuses further reservations.
    func cancelAll() {
        let tasks = state.withLock { state -> [Task<Void, Never>] in
            state.isShutDown = true
            let tasks = Array(state.tasks.values)
            state.tasks.removeAll()
            return tasks
        }
        for task in tasks {
            task.cancel()
        }
    }
}
