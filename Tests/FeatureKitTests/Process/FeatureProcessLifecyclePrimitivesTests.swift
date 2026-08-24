//
//  FeatureProcessLifecyclePrimitivesTests.swift
//  ZenCODE
//

import Foundation
@testable import FeatureKit
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Coverage for the lifecycle primitives shared by the one-shot runner and the
/// persistent session: the race-safe one-shot signal, the descriptor helpers,
/// and the bounded TERM -> grace -> KILL -> reap escalation. Every test is
/// bounded so a regression fails instead of hanging the suite.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FeatureProcessLifecyclePrimitivesTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    // MARK: - One-shot signal

    @Test
    func resolveIsIdempotentAndPublishesTheFirstValueOnly() async {
        let signal = FeatureProcessExitSignal()
        #expect(!signal.isResolved)
        #expect(signal.exitCode == nil)

        #expect(signal.resolve(7))
        #expect(!signal.resolve(9))
        #expect(signal.hasExited)
        #expect(signal.exitCode == 7)

        // A wait after resolution returns immediately.
        await signal.wait()
    }

    @Test
    func everyPendingWaiterResumesExactlyOnceOnResolution() async {
        let signal = FeatureProcessExitSignal()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await signal.wait() }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                signal.finish(exitCode: 0)
            }
            await group.waitForAll()
        }

        #expect(signal.exitCode == 0)
    }

    /// Regression: after `resolve` removed every waiter, a cancellation handler
    /// firing concurrently for that already-resumed waiter must not retain an
    /// unconsumable ticket for the lifetime of the signal.
    @Test
    func cancellationAfterResolutionRetainsNoTicket() {
        let signal = FeatureProcessExitSignal()
        #expect(signal.resolve(0))
        #expect(signal.cancellationTicketCountForTesting == 0)

        for _ in 0 ..< 128 {
            signal.simulateCancellationForTesting(waiterID: UUID())
        }

        #expect(signal.cancellationTicketCountForTesting == 0)
        #expect(signal.pendingWaiterCountForTesting == 0)
        #expect(signal.exitCode == 0)
    }

    /// A ticket recorded before resolution is dropped by `resolve`, and no waiter
    /// or ticket survives the transition.
    @Test
    func resolutionClearsPendingWaitersAndTicketsExactlyOnce() async {
        let signal = FeatureProcessExitSignal()

        signal.simulateCancellationForTesting(waiterID: UUID())
        #expect(signal.cancellationTicketCountForTesting == 1)

        signal.finish(exitCode: 3)
        #expect(signal.cancellationTicketCountForTesting == 0)
        #expect(signal.pendingWaiterCountForTesting == 0)

        // Late cancellations for that same generation stay dropped.
        signal.simulateCancellationForTesting(waiterID: UUID())
        #expect(signal.cancellationTicketCountForTesting == 0)

        await signal.wait()
        #expect(signal.pendingWaiterCountForTesting == 0)
    }

    /// Stress the real resolve/cancel interleaving through `wait()`: every task
    /// must resume exactly once (a double resume traps `CheckedContinuation`)
    /// and no waiter or ticket may remain afterwards.
    @Test
    func concurrentResolveAndCancellationLeaveNoRetainedState() async {
        for _ in 0 ..< 50 {
            let signal = FeatureProcessExitSignal()
            let waiters = (0 ..< 8).map { _ in Task { await signal.wait() } }

            await withTaskGroup(of: Void.self) { group in
                group.addTask { signal.finish(exitCode: 0) }
                for waiter in waiters {
                    group.addTask { waiter.cancel() }
                }
                await group.waitForAll()
            }
            for waiter in waiters {
                await waiter.value
            }

            #expect(signal.pendingWaiterCountForTesting == 0)
            #expect(signal.cancellationTicketCountForTesting == 0)
        }
    }

    /// A waiter cancelled before its continuation is registered still consumes
    /// its ticket, so an unresolved signal never accumulates state either.
    @Test
    func cancellationBeforeRegistrationConsumesItsTicket() async {
        let signal = FeatureProcessTerminationSignal()

        for _ in 0 ..< 50 {
            let waiter = Task { await signal.wait() }
            waiter.cancel()
            await waiter.value
        }

        #expect(!signal.isResolved)
        #expect(signal.pendingWaiterCountForTesting == 0)
        #expect(signal.cancellationTicketCountForTesting == 0)
    }

    @Test
    func cancellingOneWaiterDoesNotPoisonTheSignalForLaterWaiters() async throws {
        let signal = FeatureProcessExitSignal()

        let cancelled = Task { await signal.wait() }
        cancelled.cancel()
        await cancelled.value
        #expect(!signal.isResolved)

        // A later waiter must still suspend until the real value arrives.
        let observer = Task { () -> Bool in
            await signal.wait()
            return signal.hasExited
        }
        try await Task.sleep(for: .milliseconds(20))
        signal.finish(exitCode: 3)
        #expect(await observer.value)
        #expect(signal.exitCode == 3)
    }

    @Test
    func waitReturnsWhenTheWaitingTaskIsCancelledBeforeResolution() async {
        let signal = FeatureProcessTerminationSignal()

        let waiter = Task { await signal.wait() }
        waiter.cancel()
        // Bounded by the suite time limit: a leaked continuation would hang.
        await waiter.value

        #expect(!signal.isResolved)
        #expect(signal.resolve(.stdoutLineLimit))
        #expect(signal.value == .stdoutLineLimit)
    }

    // MARK: - Descriptor helpers

    @Test
    func makeNonBlockingSetsTheFlagAndCloseQuietlyIsIdempotent() throws {
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        FeatureProcessDescriptors.makeNonBlocking(reader)
        let flags = fcntl(reader.fileDescriptor, F_GETFL)
        #expect(flags >= 0)
        #expect(flags & O_NONBLOCK != 0)

        // Invalid descriptors and repeated teardown must not trap.
        FeatureProcessDescriptors.makeNonBlocking(Int32(-1))
        FeatureProcessDescriptors.closeQuietly(pipe.fileHandleForWriting)
        FeatureProcessDescriptors.closeQuietly(reader)
        FeatureProcessDescriptors.closeQuietly(reader)
        FeatureProcessDescriptors.closeQuietly(nil)
    }

    @Test
    func ignoreSIGPIPEOnceIsIdempotent() {
        FeatureProcessDescriptors.ignoreSIGPIPEOnce()
        FeatureProcessDescriptors.ignoreSIGPIPEOnce()
    }

    // MARK: - Termination escalation

    @Test
    func escalationReapsAChildThatIgnoresSIGTERM() async throws {
        let (process, exitSignal) = try Self.launch(["-c", "trap '' TERM; sleep 30"])
        defer { FeatureProcessTreeSupervisor.terminateImmediately(process) }

        await FeatureProcessTerminationEscalator.escalate(
            process,
            exitSignal: exitSignal,
            grace: .milliseconds(300),
            reapBudget: .seconds(5)
        )

        #expect(exitSignal.hasExited)
        #expect(exitSignal.exitCode != 0)
    }

    @Test
    func escalationCompletesForAChildThatExitsOnSIGTERM() async throws {
        let (process, exitSignal) = try Self.launch(["-c", "sleep 30"])
        defer { FeatureProcessTreeSupervisor.terminateImmediately(process) }

        await FeatureProcessTerminationEscalator.escalate(
            process,
            exitSignal: exitSignal,
            grace: .seconds(2),
            reapBudget: .seconds(5)
        )

        #expect(exitSignal.hasExited)
    }

    @Test
    func escalationIsIdempotentForAnAlreadyExitedChild() async throws {
        let (process, exitSignal) = try Self.launch(["-c", "exit 5"])

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !exitSignal.hasExited, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(exitSignal.hasExited)
        #expect(exitSignal.exitCode == 5)

        // Repeated teardown of a reaped child must return promptly and must not
        // overwrite the observed exit status.
        await FeatureProcessTerminationEscalator.escalate(process, exitSignal: exitSignal)
        await FeatureProcessTerminationEscalator.escalate(process, exitSignal: exitSignal)
        FeatureProcessTreeSupervisor.terminateImmediately(process)
        #expect(exitSignal.exitCode == 5)
    }

    @Test
    func waitForExitReportsFalseWhenTheBudgetExpiresFirst() async {
        let exitSignal = FeatureProcessExitSignal()
        let start = ContinuousClock.now

        let exited = await FeatureProcessTerminationEscalator.waitForExit(
            exitSignal,
            within: .milliseconds(150)
        )

        #expect(!exited)
        #expect(ContinuousClock.now - start >= .milliseconds(100))
    }

    @Test
    func timeoutWaitReturnsPromptlyOnCancellationWithoutATimeout() async {
        let waiter = Task {
            await FeatureProcessTerminationEscalator.waitForTimeoutOrCancellation(nil)
        }
        waiter.cancel()
        // A non-cancellable sleep here would exceed the suite time limit.
        await waiter.value
    }

    private static func launch(
        _ arguments: [String]
    ) throws -> (Process, FeatureProcessExitSignal) {
        let process = Process()
        process.executableURL = shell
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let exitSignal = FeatureProcessExitSignal()
        let monitor = FeatureProcessExitMonitor { exitCode in
            exitSignal.finish(exitCode: exitCode)
        }
        monitor.install(on: process)
        try process.run()
        monitor.startMonitoring(processID: process.processIdentifier)
        return (process, exitSignal)
    }
}
