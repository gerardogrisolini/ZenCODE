//
//  ZenCODEACPBridge+ResumeTaskGraph.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The startup offer of the task graphs earlier sessions of the project left
/// incomplete, for every new ACP session: the shared controller flow
/// (``ChatSessionController/offerResumableTaskGraphs(choiceHost:)``) asks
/// through an ``ACPResumableTaskGraphChoiceHost`` once `session/new` has
/// answered, and a graph the operator resumes is moved into the new session,
/// whose id the client already knows. `session/load` and `session/resume`
/// offer nothing. The graphs of the other live ACP sessions are left out by
/// the controller (they run in other slots of the same host).
///
/// The offer runs in its own task, at most one per incarnation and only when
/// the project has graphs to offer, and is bookkept on the bridge actor only
/// (``resumableTaskGraphOffers``): a `session/prompt` of the session waits
/// for it to end (a `session/cancel` meanwhile ends that prompt as
/// `cancelled`), a `session/close` cancels it before it drains the prompt
/// handlers, and `shutdown()` cancels every one. Cancelling the task makes
/// its pending `session/request_permission` return, so the offer ends as
/// Start fresh. A project with nothing to resume runs the session exactly as
/// before.
extension ZenCODEACPBridge {
    /// The startup offer of one session incarnation.
    struct ResumableTaskGraphOffer {
        let epoch: UInt64
        let task: Task<Void, Never>
    }

    /// A `session/prompt` handler waiting for the offer of its incarnation.
    struct ResumableTaskGraphOfferWait {
        let binding: SessionBinding
        /// Set by a `session/cancel` of the incarnation while the handler
        /// waits: the prompt then ends as `cancelled` without a turn.
        var isCancelled = false
    }

    /// Whether the project in `workingDirectory` has task graphs to offer to
    /// the new session `sessionID`: graphs earlier sessions left incomplete,
    /// without those of this session and of the sessions the host's slots
    /// run now, as the controller's offer filters them. `session/new` asks it
    /// before it answers and registers an offer only when it holds, so a
    /// project with nothing to resume keeps the session exactly as before: no
    /// offer, no prompt waiting for one, nothing more on the wire.
    func hasOfferableResumableTaskGraphs(
        sessionID: String,
        workingDirectory: URL
    ) async -> Bool {
        let graphs = await sessionRunner.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        )
        guard !graphs.isEmpty else {
            return false
        }
        var excludedSessionIDs = await host.liveSessionIDs()
        excludedSessionIDs.insert(sessionID)
        return graphs.contains { !excludedSessionIDs.contains($0.sessionID) }
    }

    /// Registers the offer of the new incarnation `epoch` of `sessionID` and
    /// returns the gate that starts it.
    ///
    /// `session/new` registers it, when there is something to offer
    /// (``hasOfferableResumableTaskGraphs(sessionID:workingDirectory:)``),
    /// before its reply, so a `session/prompt`
    /// the client sends right after the reply already finds the offer and
    /// waits for it, and opens the gate once the reply, the session info and
    /// the available commands are on the wire: no `session/request_permission`
    /// reaches the client before the session it names. A gate never opened
    /// (the task is cancelled first) ends the offer without asking anything.
    func registerResumableTaskGraphOffer(
        sessionID: String,
        epoch: UInt64
    ) -> AsyncStream<Void>.Continuation {
        let (announcement, gate) = AsyncStream.makeStream(of: Void.self)
        guard let session = liveSession(id: sessionID, epoch: epoch) else {
            gate.finish()
            return gate
        }
        let controller = session.controller
        let choiceHost = ACPResumableTaskGraphChoiceHost(writer: writer, sessionID: sessionID)
        let task = Task(name: "ZenCODE.ACP.resume-task-graphs") {
            // Ends when `session/new` opens the gate, or at once when the
            // offer is cancelled first.
            for await _ in announcement {}
            if !Task.isCancelled {
                let outcome = await controller.offerResumableTaskGraphs(choiceHost: choiceHost)
                await presentResumableTaskGraphNotices(
                    outcome.notices,
                    sessionID: sessionID,
                    epoch: epoch
                )
            }
            finishResumableTaskGraphOffer(sessionID: sessionID, epoch: epoch)
        }
        resumableTaskGraphOffers[sessionID] = ResumableTaskGraphOffer(epoch: epoch, task: task)
        return gate
    }

    /// Sends the notices of the offer (``ChatTaskGraphResumeOutcome/notices``)
    /// to the editor, in order, as `agent_message_chunk` updates of the
    /// session, only while it is still the incarnation `epoch`: one chunk per
    /// notice, its text trimmed, and from the second on preceded by a blank
    /// line, so the message the client concatenates stays readable.
    func presentResumableTaskGraphNotices(
        _ notices: [ChatSessionNotice],
        sessionID: String,
        epoch: UInt64
    ) async {
        for (index, notice) in notices.enumerated() {
            guard !Task.isCancelled, liveSession(id: sessionID, epoch: epoch) != nil else {
                return
            }
            let text = ChatSessionNoticeText.text(for: notice)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            await writer.sendSessionUpdate(
                sessionID: sessionID,
                update: Self.textChunkJSONUpdate(
                    kind: "agent_message_chunk",
                    text: index == 0 ? text : "\n\n" + text
                )
            )
        }
    }

    /// Drops the bookkeeping of an offer whose task ended, only when it is
    /// still the offer of the incarnation `epoch`.
    func finishResumableTaskGraphOffer(sessionID: String, epoch: UInt64) {
        guard resumableTaskGraphOffers[sessionID]?.epoch == epoch else {
            return
        }
        resumableTaskGraphOffers.removeValue(forKey: sessionID)
    }

    /// Cancels the offer of the incarnation `epoch` of `sessionID`, without
    /// suspending, and returns its task so the caller can wait for it to end.
    /// `nil` when that incarnation offers nothing (any more).
    func cancelResumableTaskGraphOffer(
        sessionID: String,
        epoch: UInt64
    ) -> Task<Void, Never>? {
        guard let offer = resumableTaskGraphOffers[sessionID], offer.epoch == epoch else {
            return nil
        }
        resumableTaskGraphOffers.removeValue(forKey: sessionID)
        offer.task.cancel()
        return offer.task
    }

    /// Cancels every offer, without suspending, and returns their tasks:
    /// for `shutdown()`.
    func cancelAllResumableTaskGraphOffers() -> [Task<Void, Never>] {
        let tasks = resumableTaskGraphOffers.values.map(\.task)
        resumableTaskGraphOffers.removeAll()
        for task in tasks {
            task.cancel()
        }
        return tasks
    }

    /// Waits, when the incarnation `epoch` of `sessionID` is still offering
    /// old task graphs, until the offer ends, so the prompt `promptHandlerToken`
    /// runs on the graph the operator resumed. The caller registered the
    /// handler (`enterPromptHandler`) first, so a close drains it as any
    /// running prompt.
    ///
    /// Returns `false` when the prompt must end as `cancelled` without a
    /// turn: a `session/cancel` of the incarnation arrived meanwhile, or the
    /// incarnation is gone (a `session/close`, whose cancellation of the
    /// offer is what ended the wait). Throws the shutdown fence after a
    /// `shutdown()`, so the prompt is abandoned silently.
    func waitForResumableTaskGraphOffer(
        sessionID: String,
        epoch: UInt64,
        promptHandlerToken: UUID
    ) async throws -> Bool {
        guard let offer = resumableTaskGraphOffers[sessionID], offer.epoch == epoch else {
            return true
        }
        promptsAwaitingResumableTaskGraphOffer[promptHandlerToken] = ResumableTaskGraphOfferWait(
            binding: SessionBinding(sessionID: sessionID, epoch: epoch)
        )
        await offer.task.value
        let wait = promptsAwaitingResumableTaskGraphOffer.removeValue(forKey: promptHandlerToken)
        try ensureNotShutDown()
        return wait?.isCancelled != true && liveSession(id: sessionID, epoch: epoch) != nil
    }

    /// Marks every prompt of the incarnation `epoch` of `sessionID` that is
    /// waiting for the offer as cancelled, for `session/cancel`. The offer
    /// itself goes on: the client answers its pending
    /// `session/request_permission` with `cancelled`, which ends it.
    func cancelPromptsAwaitingResumableTaskGraphOffer(sessionID: String, epoch: UInt64) {
        let binding = SessionBinding(sessionID: sessionID, epoch: epoch)
        for (token, wait) in promptsAwaitingResumableTaskGraphOffer where wait.binding == binding {
            promptsAwaitingResumableTaskGraphOffer[token]?.isCancelled = true
        }
    }
}
