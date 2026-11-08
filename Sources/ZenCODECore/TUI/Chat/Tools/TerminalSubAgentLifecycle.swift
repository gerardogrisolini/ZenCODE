//
//  TerminalSubAgentLifecycle.swift
//  ZenCODE
//
//  The lifecycle of a sub-agent in a snapshot, shared by the `/subagent`
//  detail controller and its snapshot mailbox.
//

/// The lifecycle of a sub-agent in a snapshot: its status, whether it is
/// pending, and its execution revision. A change of it is applied, and the
/// transcript read, without waiting for the throttle.
struct TerminalSubAgentLifecycle: Equatable, Sendable {
    let status: DirectSubAgentRuntime.Status
    let pending: Bool
    let executionRevision: UInt64

    init(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) {
        status = snapshot.status
        pending = snapshot.pending
        executionRevision = snapshot.executionRevision
    }
}
