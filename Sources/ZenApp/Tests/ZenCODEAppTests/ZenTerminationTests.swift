//
//  ZenTerminationTests.swift
//  ZenApp
//
//  How a quit request proceeds, and the one bounded reply to a deferred one.
//

import AppKit
import Foundation
import Testing

@testable import ZenCODEApp

@Suite("Termination step")
@MainActor
struct ZenTerminationStepTests {
    @Test("a shutdown that already runs answers every later request")
    func alreadyShuttingDown() {
        let launches: [ZenAppLauncher.LaunchState] = [
            .notStarted, .launching, .ready(isShutDown: false), .ready(isShutDown: true), .failed,
        ]
        for launch in launches {
            #expect(ZenAppLauncher.terminationStep(isShuttingDown: true, launch: launch) == .alreadyShuttingDown)
        }
    }

    @Test("a launch in progress or a runtime that is up shuts down first")
    func shutDownFirst() {
        #expect(ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .launching) == .shutDownFirst)
        #expect(
            ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .ready(isShutDown: false))
                == .shutDownFirst
        )
    }

    @Test("nothing to shut down quits at once")
    func terminateNow() {
        #expect(ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .notStarted) == .terminateNow)
        #expect(ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .failed) == .terminateNow)
        #expect(
            ZenAppLauncher.terminationStep(isShuttingDown: false, launch: .ready(isShutDown: true))
                == .terminateNow
        )
    }

    @Test("a launcher that never started quits at once")
    func launcherNotStarted() {
        let launcher = ZenAppLauncher()
        #expect(launcher.launchState == .notStarted)
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
            reply: { record.replies += 1 }
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
    }
}
