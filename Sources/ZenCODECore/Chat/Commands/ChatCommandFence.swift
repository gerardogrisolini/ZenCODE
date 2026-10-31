//
//  ChatCommandFence.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Proof that a command still acts for the request that started it.
///
/// A channel that routes its commands from another isolation domain (the ACP
/// bridge actor) takes a fence from the session's controller in the same
/// synchronous step that checks its own reservation of the request
/// (``ChatSessionController/beginCommandFence(sessionID:)``). The fence is
/// the controller's turn token, so
/// ``ChatSessionController/cancelActiveTurn(armingWorkflowRecovery:)`` (the
/// step ACP's `session/cancel`, `session/close` and shutdown take while they
/// drop the request) invalidates it.
///
/// The planning commands check the fence under the controller's lock, in the
/// step that writes their state
/// (``ChatSessionController/commitCommandState(_:_:)``). Once the fence fails
/// they write nothing more, undo the runtime changes they already made (a
/// created task graph, a replaced history, a resumed workflow) and return.
/// The channel then sees the fence fail
/// (``ChatSessionController/isCurrent(_:)``) and ends the request as
/// cancelled. A channel that runs its commands one at a time on the
/// controller's actor (the terminal) passes no fence, and the commands write
/// as they always did.
struct ChatCommandFence: Sendable, Equatable {
    /// The turn token the fence holds.
    let token: UUID
    /// The session the command runs on.
    let sessionID: String
}

extension ChatSessionController {
    /// Takes the turn token for a command the channel is about to route on
    /// `sessionID`, invalidating any token a previous turn left.
    ///
    /// Nonisolated and synchronous, so a channel on another actor takes it in
    /// the same step that checks its own reservation, with no suspension a
    /// cancellation could slip into.
    nonisolated func beginCommandFence(sessionID: String) -> ChatCommandFence {
        let token = UUID()
        stateStore.withLock { $0.activeTurnToken = token }
        return ChatCommandFence(token: token, sessionID: sessionID)
    }

    /// `true` while nothing invalidated `fence`: no cancellation and no other
    /// turn took the token.
    nonisolated func isCurrent(_ fence: ChatCommandFence) -> Bool {
        stateStore.withLock { $0.activeTurnToken == fence.token }
    }

    /// Releases the token `fence` holds, if it still holds it. A turn that
    /// started meanwhile keeps its own.
    nonisolated func endCommandFence(_ fence: ChatCommandFence) {
        stateStore.withLock { state in
            if state.activeTurnToken == fence.token {
                state.activeTurnToken = nil
            }
        }
    }

    /// Runs `body` on the command state while `fence` holds, in the same
    /// locked step that checks it; `false` (without running `body`) once it
    /// failed. For a channel on another actor, which checks the token only:
    /// the session of an ACP controller never changes.
    @discardableResult
    nonisolated func commitCommandState(
        ifCurrent fence: ChatCommandFence,
        _ body: (inout ChatCommandState) -> Void
    ) -> Bool {
        stateStore.withLock { state in
            guard state.activeTurnToken == fence.token else {
                return false
            }
            body(&state.commandState)
            return true
        }
    }

    /// `true` while a command started under `fence` may still act. No fence
    /// is always current.
    func isCommandCurrent(_ fence: ChatCommandFence?) -> Bool {
        guard let fence else {
            return true
        }
        return isCurrentTurn(fence.token, sessionID: fence.sessionID)
    }

    /// Runs `body` on the command state in one locked step: under `fence`
    /// only while it holds (`false`, without running `body`, once it
    /// failed); without a fence always, as the terminal always wrote.
    @discardableResult
    func commitCommandState(
        _ fence: ChatCommandFence?,
        _ body: (inout ChatCommandState) -> Void
    ) -> Bool {
        guard let fence else {
            stateStore.withLock { body(&$0.commandState) }
            return true
        }
        return updateCommandStateIfCurrent(fence.token, sessionID: fence.sessionID, body)
    }
}
