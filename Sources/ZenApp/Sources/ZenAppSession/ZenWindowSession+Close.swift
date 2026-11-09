//
//  ZenWindowSession+Close.swift
//  ZenApp
//
//  The end of a window: its close, the runtime's shutdown, and the
//  cancellation of its work.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Close

    /// Ends the window. It writes nothing from now on; its shared-chat
    /// observation is detached; one chat-actor step closes the slot, which
    /// fences the turn that runs, drops its reservation, and refuses the open
    /// requests before it suspends; the task-graph observer is stopped; then
    /// the window's tasks are cancelled and the runtime forgets the window.
    public func close() async {
        guard !isClosed else { return }
        let detach = closeAtOnce()
        await ZenWindowSteps.close(sessionHost, slotID: slotID)
        cancelWork()
        await detach?.value
        runtime?.windowDidClose(self)
    }

    /// Marks the window closed, drops its queue, and stops its shared-chat
    /// observation at once, for the runtime's shutdown: the window writes
    /// nothing from now on. Its work is cancelled by the runtime
    /// (``cancelWork()``) only after the host shutdown fenced every
    /// controller, so a cancelled turn cannot write back first. A second call
    /// does nothing.
    func markClosed() {
        guard !isClosed else { return }
        closeAtOnce()
    }

    /// The steps ``close()`` and ``markClosed()`` take at once, in this order
    /// and before anything suspends: the window is closed, so it writes
    /// nothing from now on; its queue is dropped; the indicator of a sidebar
    /// load is cleared; and its shared-chat observation is stopped. Returns
    /// the observation's detach.
    @discardableResult
    private func closeAtOnce() -> Task<Void, Never>? {
        isClosed = true
        queuedLines = []
        clearSavedSessionLoad()
        return sharedChatObservation.stop()
    }

    /// Cancels the window's tasks and leaves it idle. Called once its slot
    /// ended (``close()``, the runtime's shutdown); a second call does
    /// nothing more.
    func cancelWork() {
        incarnationTask?.cancel()
        incarnationTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        gitTask?.cancel()
        gitTask = nil
        statusTask?.cancel()
        statusTask = nil
        lineTask?.cancel()
        lineTask = nil
        lineStop = nil
        for task in besideTasks.values {
            task.cancel()
        }
        besideTasks = [:]
        for task in mentionTasks.values {
            task.cancel()
        }
        mentionTasks = [:]
        rosterTask?.cancel()
        rosterTask = nil
        adoptedTelegramTurnTask?.cancel()
        adoptedTelegramTurnTask = nil
        adoptedTelegramPromptID = nil
        sharedChatObservation.stop()
        queuedLines = []
        isBusy = false
        clearSavedSessionLoad()
        // The tabs stay as they are; their models stop.
        stopSubAgentTabs()
    }
}
