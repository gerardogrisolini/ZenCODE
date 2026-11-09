//
//  ZenTerminationTests.swift
//  ZenApp
//
//  How a quit request proceeds, the one bounded reply to a deferred one, and
//  a quit while the worktree of a `--worktree` launch is still to close.
//

import AppKit
import Foundation
import Testing

@testable import ZenCODEApp

@Suite("Termination step")
@MainActor
struct ZenTerminationStepTests {
    private let launches: [ZenAppLauncher.LaunchState] = [
        .notStarted, .launching, .ready(isShutDown: false), .ready(isShutDown: true), .failed,
    ]

    @Test("a shutdown that already runs answers every later request")
    func alreadyShuttingDown() {
        for launch in launches {
            #expect(
                ZenAppLauncher.terminationStep(isShuttingDown: true, launch: launch, worktreeClosure: .none)
                    == .alreadyShuttingDown
            )
        }
    }

    @Test("a launch in progress or a runtime that is up shuts down first")
    func shutDownFirst() {
        #expect(
            ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .launching, worktreeClosure: .none)
                == .shutDownFirst
        )
        #expect(
            ZenAppLauncher.terminationStep(
                isShuttingDown: false,
                launch: .ready(isShutDown: false),
                worktreeClosure: .none
            ) == .shutDownFirst
        )
    }

    @Test("nothing to shut down quits at once")
    func terminateNow() {
        #expect(
            ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .notStarted, worktreeClosure: .none)
                == .terminateNow
        )
        #expect(
            ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .failed, worktreeClosure: .none)
                == .terminateNow
        )
        // Also once a worktree closing finished: it shut the runtime down.
        #expect(
            ZenAppLauncher.terminationStep(
                isShuttingDown: false,
                launch: .ready(isShutDown: true),
                worktreeClosure: .none
            ) == .terminateNow
        )
    }

    @Test("a worktree still to close is asked first, whatever the launch")
    func askWorktreeClosure() {
        for launch in launches {
            for isShuttingDown in [false, true] {
                #expect(
                    ZenAppLauncher.terminationStep(
                        isShuttingDown: isShuttingDown,
                        launch: launch,
                        worktreeClosure: .pending
                    ) == .askWorktreeClosure
                )
            }
        }
    }

    @Test("a worktree whose closing runs cancels the request, whatever the launch")
    func worktreeClosureRuns() {
        for launch in launches {
            for isShuttingDown in [false, true] {
                #expect(
                    ZenAppLauncher.terminationStep(
                        isShuttingDown: isShuttingDown,
                        launch: launch,
                        worktreeClosure: .running
                    ) == .alreadyShuttingDown
                )
            }
        }
    }

    @Test("a launcher that never started quits at once")
    func launcherNotStarted() {
        let launcher = ZenAppLauncher()
        #expect(launcher.launchState == .notStarted)
        #expect(launcher.readyRuntime == nil)
        #expect(launcher.worktreeClosureState == .none)
        #expect(launcher.terminationStep() == .terminateNow)
    }

    @Test("a quit waits about 5 seconds at most")
    func timeout() {
        #expect(ZenAppLauncher.terminationTimeout == .seconds(5))
    }
}

@Suite("Termination gate")
@MainActor
struct ZenTerminationGateTests {
    /// What the gate's tasks record, in order.
    @MainActor
    final class Record {
        var outcomes: [ZenTerminationGate.Outcome] = []
        var shutdownRuns = 0
        var shutdownEnded = false
        var replies = 0
        var steps = 0
        var worktreeRequests = 0
    }

    /// Waits until `condition` holds, for at most `timeout`; records an issue
    /// when the deadline passes.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        sourceLocation: SourceLocation = #_sourceLocation,
        _ condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("a shutdown that ends first replies once; the timer does not reply again")
    func shutdownFirst() async {
        let record = Record()
        let gate = ZenTerminationGate { record.outcomes.append($0) }
        gate.start(timeout: .milliseconds(150)) {}
        await waitUntil { !record.outcomes.isEmpty }
        // Past the timeout: the cancelled timer adds nothing.
        try? await Task.sleep(for: .milliseconds(400))
        #expect(record.outcomes == [.shutDown])
        #expect(gate.outcome == .shutDown)
    }

    @Test("a shutdown that outlasts the timeout is answered by the timer, once")
    func timeoutFirst() async {
        let record = Record()
        let gate = ZenTerminationGate { record.outcomes.append($0) }
        let (stream, release) = AsyncStream<Void>.makeStream()
        gate.start(timeout: .milliseconds(30)) {
            for await _ in stream {}
            record.shutdownEnded = true
        }
        await waitUntil { !record.outcomes.isEmpty }
        #expect(record.outcomes == [.timedOut])
        #expect(!record.shutdownEnded)

        // The shutdown ends later: no second reply.
        release.finish()
        await waitUntil { record.shutdownEnded }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(record.outcomes == [.timedOut])
        #expect(gate.outcome == .timedOut)
    }

    @Test("the gate settles once and starts once")
    func settlesOnce() async {
        let record = Record()
        let gate = ZenTerminationGate { record.outcomes.append($0) }
        #expect(gate.settle(.timedOut))
        #expect(!gate.settle(.shutDown))
        #expect(!gate.settle(.timedOut))
        #expect(record.outcomes == [.timedOut])

        // Starting a settled gate runs the shutdown but replies nothing more.
        gate.start(timeout: .milliseconds(10)) { record.shutdownRuns += 1 }
        gate.start(timeout: .milliseconds(10)) { record.shutdownRuns += 1 }
        await waitUntil { record.shutdownRuns == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(record.shutdownRuns == 1)
        #expect(record.outcomes == [.timedOut])
    }

    @Test("a second quit request before the shutdown started is cancelled; the app replies once")
    func secondRequestWhileTheGateWaits() async {
        let record = Record()
        let (stream, release) = AsyncStream<Void>.makeStream()
        let delegate = ZenAppDelegate()
        delegate.termination = ZenAppDelegate.Termination(
            // The launcher does not see a shutdown that has not started yet.
            step: {
                record.steps += 1
                return .shutDownFirst
            },
            shutdown: {
                record.shutdownRuns += 1
                for await _ in stream {}
                record.shutdownEnded = true
            },
            reply: { record.replies += 1 },
            requestWorktreeClosure: { record.worktreeRequests += 1 }
        )

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        let gate = delegate.terminationGate
        #expect(gate != nil)
        // At once, before the gate's shutdown task ran.
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(delegate.terminationGate === gate)
        #expect(record.steps == 1)

        release.finish()
        await waitUntil { record.shutdownEnded && record.replies == 1 }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(record.replies == 1)
        #expect(record.shutdownRuns == 1)
        #expect(gate?.outcome == .shutDown)
        #expect(record.worktreeRequests == 0)
    }
}

@Suite("Termination with a worktree")
@MainActor
struct ZenWorktreeTerminationTests {
    /// What the delegate's termination ran; `step` is what it answers.
    @MainActor
    final class Record {
        var step: ZenAppLauncher.TerminationStep = .askWorktreeClosure
        var shutdownRuns = 0
        var replies = 0
        var worktreeRequests = 0
    }

    private func delegate(recording record: Record) -> ZenAppDelegate {
        let delegate = ZenAppDelegate()
        delegate.termination = ZenAppDelegate.Termination(
            step: { record.step },
            shutdown: { record.shutdownRuns += 1 },
            reply: { record.replies += 1 },
            requestWorktreeClosure: { record.worktreeRequests += 1 }
        )
        return delegate
    }

    @Test("a quit with the worktree still to close asks it and is cancelled, every time")
    func askWorktreeClosure() {
        let record = Record()
        let delegate = delegate(recording: record)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(record.worktreeRequests == 1)
        // Again, with only the Worktree window open: asked again (the
        // closure is requested once), cancelled again.
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(record.worktreeRequests == 2)
        #expect(delegate.terminationGate == nil)
        #expect(record.shutdownRuns == 0)
        #expect(record.replies == 0)
    }

    @Test("a quit while the closing runs is cancelled without a gate; once it ended the app quits at once")
    func whileTheClosingRuns() {
        let record = Record()
        record.step = .alreadyShuttingDown
        let delegate = delegate(recording: record)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(delegate.terminationGate == nil)

        // The closing ended and shut the runtime down.
        record.step = .terminateNow
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        #expect(delegate.terminationGate == nil)
        #expect(record.shutdownRuns == 0)
        #expect(record.replies == 0)
        #expect(record.worktreeRequests == 0)
    }

    @Test("without a runtime the app quits with its last window")
    func lastWindowWithoutARuntime() {
        let delegate = ZenAppDelegate()
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }
}
