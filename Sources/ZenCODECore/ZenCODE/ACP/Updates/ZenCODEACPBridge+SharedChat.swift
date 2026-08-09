//
//  ZenCODEACPBridge+SharedChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Renders shared-chat traffic (`agent.message`) into the ACP session.
///
/// Without this, a sub-agent that reports through the shared bus is visible only
/// in the terminal UI: an ACP host receives the coordinator's own turns and
/// nothing else, so the message the agent sent is silently lost for that client.
///
/// The renderer is deliberately *not* stored in `SessionState`. That value is
/// rebuilt wholesale by a snapshot refresh, by `@agent` routing inside a prompt
/// and by every `set_model` / `set_config_option` commit, so a handle living
/// there is dropped by paths that know nothing about it. It lives instead in a
/// bridge-scoped registry keyed by session id, whose entries are guarded by the
/// same epoch the session carries.
extension ZenCODEACPBridge {
    // MARK: - Attach

    /// Attaches exactly one shared-chat observer for this session incarnation.
    ///
    /// The reservation is published *before* the first suspension, so a second
    /// call for the same session — a `session/load` racing a `session/resume`,
    /// or any reentrant lifecycle handler — observes it and returns instead of
    /// attaching a second observer that would render every message twice.
    func startSharedChatForwarding(sessionID: String, epoch: UInt64) async {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              sharedChatForwarders[sessionID] == nil else {
            return
        }
        let roomID = session.configuration.sessionID
        // Keep the whole attach operation in the reservation, rather than only
        // its eventual observation. A close/shutdown can therefore await an
        // attach that is still suspended, instead of returning while that attach
        // later creates an observer which has nobody left to own it.
        let barrier = sharedChatAttachBarrier
        let attachTask = Task { [weak self, sessionRunner] in
            await barrier?()
            let observation = await sessionRunner.attachSharedChatObservation(
                rootSessionID: roomID
            )
            await self?.completeSharedChatAttach(
                sessionID: sessionID,
                epoch: epoch,
                observation: observation
            )
        }
        sharedChatForwarders[sessionID] = SharedChatForwarder(
            epoch: epoch,
            attachTask: attachTask
        )
        await attachTask.value
    }

    /// Publishes an attached observation, or releases it if its reservation was
    /// removed while `attachSharedChatObservation` suspended.
    private func completeSharedChatAttach(
        sessionID: String,
        epoch: UInt64,
        observation: AgentSharedChatCoordinator.Observation
    ) async {
        // The attach suspends. A `session/close` or a `shutdown` can land
        // inside it, and both take the reservation away; a newer incarnation
        // may already own the entry. In either case this observer belongs to
        // nobody, and the entry is not ours to remove.
        guard let reservation = sharedChatForwarders[sessionID],
              reservation.epoch == epoch,
              reservation.observation == nil else {
            await sessionRunner.detachSharedChatObservation(observation)
            return
        }
        // Our own reservation outlived its session (a rollback discarded the
        // incarnation while we were attaching). Drop it, or the stale entry
        // would keep a future incarnation of the same id from ever attaching.
        guard liveSession(id: sessionID, epoch: epoch) != nil else {
            sharedChatForwarders.removeValue(forKey: sessionID)
            await sessionRunner.detachSharedChatObservation(observation)
            return
        }
        let task = Self.makeSharedChatForwardingTask(
            sessionID: sessionID,
            observation: observation,
            writer: writer
        )
        sharedChatForwarders[sessionID]?.observation = observation
        sharedChatForwarders[sessionID]?.task = task
    }

    /// The forwarding loop.
    ///
    /// It is built as a `static` helper over the writer alone: the task must
    /// never call back into the bridge actor, or a teardown awaiting its
    /// quiescence would deadlock against its own reentrancy.
    private static func makeSharedChatForwardingTask(
        sessionID: String,
        observation: AgentSharedChatCoordinator.Observation,
        writer: ACPWriter
    ) -> Task<Void, Never> {
        Task(name: "ZenCODEACPBridge.shared-chat-forwarding") {
            forwarding: for await event in observation.events {
                guard !Task.isCancelled else {
                    break forwarding
                }
                guard case let .messages(messages) = event else {
                    // Roster changes and auto-triggers are Core-owned: a
                    // renderer neither claims a turn nor answers an offer.
                    continue
                }
                // Cancellation is re-checked inside the batch, not only between
                // events: a teardown that awaits this task must not be held for
                // the length of a full transcript replay.
                for message in messages {
                    guard !Task.isCancelled else {
                        break forwarding
                    }
                    guard let update = sharedChatUpdate(for: message) else {
                        continue
                    }
                    await writer.sendSessionUpdate(sessionID: sessionID, update: update)
                }
            }
        }
    }

    // MARK: - Teardown

    /// Ends the renderer bound to this session id and waits for its quiescence.
    ///
    /// Cancelling alone is not enough: the task may already be suspended inside
    /// a write. Awaiting it is what lets `session/close` guarantee that no
    /// further `session/update` is emitted for a session it already answered.
    func stopSharedChatForwarding(sessionID: String) async {
        guard let forwarder = sharedChatForwarders.removeValue(forKey: sessionID) else {
            return
        }
        await finishSharedChatForwarding(forwarder)
    }

    /// Cancels, awaits and detaches one renderer. Safe on a reservation whose
    /// attach is still in flight: it owns the eventual detach after finding its
    /// entry gone. Awaiting it before returning is what makes close/shutdown
    /// wait for both attach and detach.
    func finishSharedChatForwarding(_ forwarder: SharedChatForwarder) async {
        forwarder.attachTask.cancel()
        forwarder.task?.cancel()
        await forwarder.attachTask.value
        await forwarder.task?.value
        if let observation = forwarder.observation {
            await sessionRunner.detachSharedChatObservation(observation)
        }
    }

    // MARK: - Wire mapping

    /// Maps one shared-chat message to an ACP v1 chunk that standard clients
    /// already render. ACP has no sender field on chunks, so the sender is
    /// preserved in the visible text.
    ///
    /// Returns `nil` for operator traffic: that text is the host's own prompt,
    /// already displayed by the client and already echoed by the bridge as a
    /// user chunk. Re-emitting it here would show the operator's input twice.
    /// The bug this renders is `agent.message`, so only agent and coordinator
    /// senders are forwarded.
    public static func sharedChatUpdate(for message: AgentSharedChat.Message) -> JSONValue? {
        guard message.sender.kind != .operator else {
            return nil
        }
        return .object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object([
                "type": .string("text"),
                "text": .string("[\(message.sender.name)] \(message.text)")
            ])
        ])
    }
}
