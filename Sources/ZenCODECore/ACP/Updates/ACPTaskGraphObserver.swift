//
//  ACPTaskGraphObserver.swift
//  ZenCODE
//
//  The live publication of a session's task graph to the ACP client: the
//  `plan` update — the client's Tasks section — follows the graph while the
//  session is idle, as the terminal's and the host app's overviews do.
//

import Foundation

/// The incarnation's observer of the session's task-graph events.
///
/// A prompt publishes the plan itself, from the graph observer its presentation
/// starts (``ZenCODEACPBridge/startPromptTurnPresentation(_:session:pipeline:)``),
/// through the turn's update pipeline, so the Tasks section follows a turn as it
/// runs and never overtakes the content that turn produced. The graph also
/// changes outside a prompt — a resumed graph adopted before a turn, a turn run
/// from the linked Telegram chat, a change between two turns — and a client that
/// shows the plan has to follow those too, as the terminal and the host app do
/// by observing the graph for the whole session.
///
/// This observer subscribes to the same events for the whole incarnation and
/// publishes the plan of every change. While a prompt owns the update pipeline
/// it publishes nothing, because the prompt's presentation and its final
/// publication cover the graph then, with the pipeline's ordering; the prompt
/// keeps its pipeline installed until that final publication drained, so the
/// two never publish the same graph side by side. A turn that ends by
/// cancellation has no final publication, so its end reconciles the section
/// (``ZenCODEACPBridge/publishTaskGraphPlan(sessionID:epoch:)``).
///
/// Every publication — this observer's, the reconciliation's, and `/tasks`'
/// — reads the graph immediately before preparing the plan, and the projection
/// keeps a plan built from an older revision from replacing a newer one (see
/// ``ACPTaskPresentation``), so a plan is sent once per change and the section
/// never moves backwards. The observer belongs to the incarnation: a same-epoch
/// reconstruction keeps it, and a close, a discard, or a shutdown cancels it.
extension ZenCODEACPBridge {
    /// Starts the incarnation's observer, unless it already runs or the session
    /// is no longer live.
    ///
    /// The events are subscribed before the consumer starts, so a change landing
    /// after this call is seen (the stream has no replay). The graph the session
    /// already has — a session restored with one — is published from the
    /// observer's own task, as its first action, so it is serialized with the
    /// events behind it.
    func startTaskGraphObserverIfNeeded(sessionID: String, epoch: UInt64) async {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              session.taskGraphObserver == nil else {
            return
        }
        let stream = await sessionRunner.taskOrchestrator.events(sessionID: sessionID)
        let observer = Task(name: "ZenCODE.ACP.task-graph-observer") { [weak self] in
            guard !Task.isCancelled, let self else { return }
            await self.publishTaskGraphPlan(sessionID: sessionID, epoch: epoch)
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self.publishTaskGraphPlan(sessionID: sessionID, epoch: epoch)
            }
        }
        // Stored under the liveness check, and only when none is running yet:
        // two creations of one incarnation never leave an observer behind.
        var started = false
        updateLiveSession(id: sessionID, epoch: epoch) { live in
            guard live.taskGraphObserver == nil else { return }
            live.taskGraphObserver = observer
            started = true
        }
        guard started else {
            observer.cancel()
            return
        }
    }

    /// Publishes the `plan` of the session's graph when it changed, unless a
    /// prompt owns the presentation: the prompt's own observer publishes it
    /// then, and its pipeline fixes the order of what reaches the client.
    ///
    /// `force` publishes the section even when it is the one already presented,
    /// for the restore of an id the client is still holding; otherwise a change
    /// that leaves the section as it is sends nothing. A snapshot that cannot be
    /// read publishes nothing, and so does a session that closed while the graph
    /// was read: an unavailable read is not an authoritative clear.
    func publishTaskGraphPlan(sessionID: String, epoch: UInt64, force: Bool = false) async {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              session.promptUpdatePipeline == nil else {
            return
        }
        let graph: TaskGraphSnapshot?
        do {
            graph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID)
        } catch {
            return
        }
        guard !Task.isCancelled,
              let live = liveSession(id: sessionID, epoch: epoch),
              live.promptUpdatePipeline == nil,
              let plan = await live.taskPresentation.planToPresent(for: graph, force: force) else {
            return
        }
        // The last check before the write: the plan of a session that closed
        // meanwhile would reach a client that no longer has it.
        guard liveSession(id: sessionID, epoch: epoch) != nil else {
            return
        }
        await writer.sendSessionUpdate(sessionID: sessionID, update: plan)
        await live.taskPresentation.acknowledge(plan)
    }
}
