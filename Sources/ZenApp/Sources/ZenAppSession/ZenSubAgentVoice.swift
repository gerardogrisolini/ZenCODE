//
//  ZenSubAgentVoice.swift
//  ZenApp
//
//  What voice mode reads of a delegated agent: the comment it writes before a
//  tool call, live, while its tab is the selected one of the active window.
//

import Foundation
import Synchronization

/// The comment a delegated agent wrote right before a tool call, as the
/// window's presenter hands it over: with the identity of what wrote it (the
/// incarnation of the slot, the agent, the call it precedes), so voice reads
/// it only while that agent's tab of that incarnation is the one shown.
struct ZenSubAgentCommentary: Sendable, Equatable {
    /// The epoch of the incarnation the slot ran when the event was presented.
    let epoch: UInt64
    let agentID: String
    /// The tool call the comment precedes.
    let toolCallID: String
    /// The comment; never blank.
    let text: String
}

/// What voice mode follows in a window besides the coordinator: the sub-agent
/// tab the window shows, if any. The window writes it from the main actor
/// whenever the selection, the incarnation, or the window's life changes; the
/// chat actor reads it at once, when a delegated agent's event is presented,
/// and again in the voice context, when the request is handled.
///
/// Every change of the selection starts a new ``State/generation``, also one
/// that goes back to a tab shown before (A, B, A), so what was stamped with
/// an earlier generation is stale whatever the selection is now.
final class ZenVoiceTabSource: Sendable {
    /// The sub-agent tab shown: the agent, in the incarnation the tab was
    /// opened in.
    struct Selection: Sendable, Equatable {
        let epoch: UInt64
        let agentID: String
    }

    struct State: Sendable, Equatable {
        /// `nil` while the conversation is shown, or the window is closed.
        var selection: Selection?
        /// Advanced by every change of ``selection``.
        var generation: UInt64
    }

    private let state = Mutex(State(selection: nil, generation: 0))

    init() {}

    var current: State {
        state.withLock { $0 }
    }

    /// A sub-agent tab is the one shown: the coordinator is not the source.
    var isDetailSelected: Bool {
        state.withLock { $0.selection != nil }
    }

    /// Follows the window to `selection`; `false` when it did not change.
    /// When it did, `publish` runs inside the same critical section, before
    /// the new generation is visible to anyone who reads it: what is posted
    /// there precedes, in the voice context, every request stamped with the
    /// new generation. It must not wait.
    @discardableResult
    func select(_ selection: Selection?, publishing publish: () -> Void) -> Bool {
        state.withLock { state in
            guard state.selection != selection else { return false }
            publish()
            state.selection = selection
            state.generation &+= 1
            return true
        }
    }

    /// The generation `commentary` is stamped with, when its agent's tab is
    /// the one shown, in the incarnation it was written in; `nil` otherwise.
    func generation(admitting commentary: ZenSubAgentCommentary) -> UInt64? {
        state.withLock { state in
            let source = Selection(epoch: commentary.epoch, agentID: commentary.agentID)
            return state.selection == source ? state.generation : nil
        }
    }

    /// Whether a sub-agent tab is still shown, and it is the one `generation`
    /// stamped.
    func admits(generation: UInt64) -> Bool {
        state.withLock { $0.selection != nil && $0.generation == generation }
    }
}
