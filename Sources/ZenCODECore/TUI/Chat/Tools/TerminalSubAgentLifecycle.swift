//
//  TerminalSubAgentLifecycle.swift
//  ZenCODE
//
//  The lifecycle of a sub-agent in a snapshot and the key that decides when
//  its transcript is read again, shared by the `/subagent` detail controller,
//  the snapshot mailbox, and the sub-agent tabs of the macOS app.
//

import Foundation
import ZenCODERuntime

/// The lifecycle of a sub-agent in a snapshot: its status, whether it is
/// pending, and its execution revision. A change of it is applied, and the
/// transcript read, without waiting for the throttle.
public struct TerminalSubAgentLifecycle: Equatable, Sendable {
    public let status: DirectSubAgentRuntime.Status
    public let pending: Bool
    public let executionRevision: UInt64

    public init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        status = snapshot.status
        pending = snapshot.pending
        executionRevision = snapshot.executionRevision
    }
}

/// What decides that the transcript of a sub-agent may have changed: its
/// lifecycle, its completed execution, its tool and whether that tool still
/// runs (its result reaches the transcript when it stops), and its latest
/// event.
public struct TerminalSubAgentReloadKey: Equatable, Sendable {
    public let lifecycle: TerminalSubAgentLifecycle
    public let completedExecutionRevision: UInt64
    public let toolName: String?
    public let toolIsRunning: Bool
    public let latestEventAt: Date?
    public let updatedAt: Date

    public init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        lifecycle = TerminalSubAgentLifecycle(snapshot)
        completedExecutionRevision = snapshot.completedExecutionRevision
        toolName = snapshot.currentToolName
        toolIsRunning = snapshot.currentToolIsRunning
        latestEventAt = snapshot.latestEventAt
        updatedAt = snapshot.updatedAt
    }
}
