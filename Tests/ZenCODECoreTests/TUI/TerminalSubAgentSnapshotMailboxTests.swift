//
//  TerminalSubAgentSnapshotMailboxTests.swift
//  ZenCODE
//
//  The mailbox that hands the newest sub-agent snapshots to the `/subagent`
//  detail controller and to the sub-agent tabs of the macOS app: the newest
//  value kept, the lifecycle changes flagged, the waits that end, and the
//  throttle a lifecycle change cuts short.
//

import Foundation
import Testing
@testable import ZenCODECore

private let referenceDate = Date(timeIntervalSinceReferenceDate: 1_000)

private func agent(
    _ id: String = "agent-1",
    status: DirectSubAgentRuntime.Status = .running,
    second: TimeInterval = 0
) -> DirectSubAgentRuntime.AgentSnapshot {
    DirectSubAgentRuntime.AgentSnapshot(
        id: id,
        name: "Worker \(id)",
        status: status,
        pending: status.isPending,
        currentActivity: nil,
        currentActivityKind: nil,
        currentThought: nil,
        currentToolName: nil,
        currentToolIsRunning: false,
        latestEventAt: referenceDate.addingTimeInterval(second),
        latestOutput: nil,
        executionRevision: 0,
        latestError: nil,
        createdAt: referenceDate,
        updatedAt: referenceDate.addingTimeInterval(second)
    )
}

@Suite("Sub-agent snapshot mailbox")
struct TerminalSubAgentSnapshotMailboxTests {
    @Test("It keeps the newest value and flags the lifecycle changes of its agent, a replaced one too")
    func newestValueAndLifecycle() async {
        let mailbox = TerminalSubAgentSnapshotMailbox(agentID: "agent-1", lifecycle: TerminalSubAgentLifecycle(agent()))
        // A newer event of the same lifecycle replaces the value, unflagged.
        mailbox.put([agent(second: 1)])
        mailbox.put([agent(second: 2)])
        let first = await mailbox.next()
        #expect(first?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(2))
        #expect(first?.changesLifecycle == false)

        // A change that a newer value replaced still counts, and wakes the
        // wait for a change.
        mailbox.put([agent(status: .idle, second: 3)])
        mailbox.put([agent(status: .running, second: 4)])
        await mailbox.waitForLifecycleChange()
        let second = await mailbox.next()
        #expect(second?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(4))
        #expect(second?.changesLifecycle == true)

        // Another agent's change, or a value without the agent, is not one.
        mailbox.put([agent("agent-2", status: .idle)])
        #expect(await mailbox.next()?.changesLifecycle == false)
        // The comparison is with the last value taken that had the agent.
        mailbox.put([agent(status: .idle, second: 5)])
        #expect(await mailbox.next()?.changesLifecycle == true)
        mailbox.put([agent(status: .idle, second: 6)])
        #expect(await mailbox.next()?.changesLifecycle == false)

        // Finished: the value not taken yet, then nothing.
        mailbox.put([agent(status: .idle, second: 7)])
        mailbox.finish()
        #expect(await mailbox.next()?.snapshots.first?.latestEventAt == referenceDate.addingTimeInterval(7))
        #expect(await mailbox.next() == nil)
    }

    @Test("Its waits end when a value comes, when it finishes, or when their task is cancelled")
    func waitsEnd() async {
        let mailbox = TerminalSubAgentSnapshotMailbox(agentID: "agent-1", lifecycle: nil)
        let waitingValue = Task { await mailbox.next()?.snapshots.count }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.put([agent()])
        #expect(await waitingValue.value == 1)

        let cancelledValue = Task { await mailbox.next() == nil }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledValue.cancel()
        #expect(await cancelledValue.value)

        let cancelledChange = Task { await mailbox.waitForLifecycleChange() }
        try? await Task.sleep(for: .milliseconds(20))
        cancelledChange.cancel()
        await cancelledChange.value

        let finished = Task { await mailbox.next() == nil }
        try? await Task.sleep(for: .milliseconds(20))
        mailbox.finish()
        #expect(await finished.value)
    }

    @Test("Its throttle waits the interval, ends early on a lifecycle change, and fails with the sleep")
    func throttleEnds() async {
        let mailbox = TerminalSubAgentSnapshotMailbox(agentID: "agent-1", lifecycle: TerminalSubAgentLifecycle(agent()))
        let elapsed = await mailbox.throttle(interval: .milliseconds(1)) { try await Task.sleep(for: $0) }
        #expect(elapsed == .elapsed)

        mailbox.put([agent(status: .idle)])
        let changed = await mailbox.throttle(interval: .seconds(60)) { try await Task.sleep(for: $0) }
        #expect(changed == .lifecycleChanged)

        _ = await mailbox.next()
        let failed = await mailbox.throttle(interval: .seconds(60)) { _ in throw CancellationError() }
        #expect(failed == .failed)
    }
}
