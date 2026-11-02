//
//  ChatSessionIncarnation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation

/// What a session incarnation is doing: nothing, generating the prompt
/// identified by the id, or being reconfigured by the operation identified by
/// the id. A prompt and a reconfiguration exclude each other, and so do two
/// of either: the host reserves the state before an operation's first
/// suspension, in one step with the check (see
/// ``ChatSessionHost/reservePrompt(in:)``).
public enum ChatSessionOperationState: Sendable, Equatable {
    case idle
    case prompting(UUID)
    case reconfiguring(UUID)
}

/// One session running in a slot of a ``ChatSessionHost``: a controller, the
/// reducer attached to it as it was created, and the epoch that tells this
/// incarnation apart from every other one the host ever ran, including an
/// earlier or later session with the same id. Work that suspended keeps the
/// epoch it started under and writes back only while the slot still runs it
/// (``ChatSessionHost/withLiveIncarnation(_:epoch:_:)``), so a closed or
/// replaced incarnation is never written into by its own late work.
///
/// A value: the host updates its mutable fields in place, and a copy handed
/// out is what the host knew when it was read.
public struct ChatSessionIncarnation: Sendable {
    public let slotID: ChatSlotID
    /// The id of the session, the controller's. It changes only through
    /// ``ChatSessionHost/adoptSessionID(_:in:)``, before the runtime session
    /// exists; the epoch is what tells incarnations apart.
    public internal(set) var sessionID: String
    /// Assigned by the host from one counter, strictly increasing across every
    /// slot and never reused.
    public let epoch: UInt64
    public let controller: ChatSessionController
    /// The observable state of the session, attached to ``controller`` before
    /// anything was presented, when the slot publishes state
    /// (``ChatSlotDescriptor/publishesState``); `nil` otherwise. Its
    /// ``ChatSessionSnapshot/epoch`` is ``epoch``.
    public internal(set) var reducer: ChatSessionStateReducer?
    /// The interaction host of this incarnation when the slot asks with
    /// pending requests (``ChatSlotInteraction/pendingRequests(capabilities:gatesWorkspaceAccess:openExternal:)``);
    /// `nil` when the slot brings its own host.
    public let pendingRequestHost: ChatPendingRequestHost?
    /// The prompt reserved on this incarnation, while one is.
    public internal(set) var activePromptID: UUID?
    public internal(set) var operationState: ChatSessionOperationState

    init(
        slotID: ChatSlotID,
        sessionID: String,
        epoch: UInt64,
        controller: ChatSessionController,
        reducer: ChatSessionStateReducer?,
        pendingRequestHost: ChatPendingRequestHost?
    ) {
        self.slotID = slotID
        self.sessionID = sessionID
        self.epoch = epoch
        self.controller = controller
        self.reducer = reducer
        self.pendingRequestHost = pendingRequestHost
        activePromptID = nil
        operationState = .idle
    }
}

/// The host whose slot runs a controller as one incarnation, with the slot:
/// what a hosted controller delegates its session replacements to (see
/// ``ChatSessionController/startNewSession(newSessionID:)``). The host is
/// held weakly: it owns the controller, through the slot.
struct ChatSessionHostBinding: Sendable {
    weak var host: ChatSessionHost?
    let slotID: ChatSlotID
}

/// The exclusive right to run one prompt on one incarnation, from
/// ``ChatSessionHost/reservePrompt(in:)`` to ``ChatSessionHost/releasePrompt(_:)``,
/// a cancellation, or the end of the incarnation. Work that suspended checks
/// it again before writing (``ChatSessionHost/holdsPrompt(_:)``).
public struct ChatPromptReservation: Sendable, Hashable {
    public let slotID: ChatSlotID
    public let sessionID: String
    public let epoch: UInt64
    public let promptID: UUID
}

/// The exclusive right to reconfigure one incarnation (no prompt runs
/// meanwhile), released by its owner or with the incarnation. A channel's
/// operation such as ACP `set_model` holds it across the runner call.
struct ChatReconfigurationReservation: Sendable, Hashable {
    let slotID: ChatSlotID
    let sessionID: String
    let epoch: UInt64
    let reconfigurationID: UUID
}

/// Why a ``ChatSessionHost`` operation did not run.
public enum ChatSessionHostError: Error, Equatable, Sendable {
    /// ``ChatSessionHost/shutdown()`` ran.
    case shutDown
    /// No open slot has this id.
    case unknownSlot
    /// The slot runs no session.
    case noSession
    /// The slot's session has a prompt or a reconfiguration reserved.
    case sessionBusy
    /// The project has no saved session with this name.
    case savedSessionNotFound(String)
    /// ``ChatSlotInteraction/pendingRequests(capabilities:gatesWorkspaceAccess:openExternal:)``
    /// needs ``ChatSlotDescriptor/publishesState``.
    case statePublishingRequired
}
