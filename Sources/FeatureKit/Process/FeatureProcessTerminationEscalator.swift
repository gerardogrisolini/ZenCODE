//
//  FeatureProcessTerminationEscalator.swift
//  ZenCODE
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Deterministic `SIGTERM -> grace -> SIGKILL -> reap` escalation driven by an
/// observed exit signal rather than by Foundation's `Process.isRunning`.
///
/// The one-shot runner drives this from its exit supervisor; every wait here is
/// bounded, so a child that ignores SIGTERM, or a platform whose `waitpid`
/// bookkeeping is delayed, can never suspend a feature run indefinitely.
enum FeatureProcessTerminationEscalator {
    /// Grace window granted to a child after SIGTERM before SIGKILL is sent.
    static let defaultGrace: Duration = .seconds(2)
    /// Bounded budget for observing the exit of an already SIGKILLed child.
    static let defaultReapBudget: Duration = .seconds(5)

    /// Suspends until `timeout` elapses or the task is cancelled. With no
    /// timeout it suspends until cancellation only: `Task.sleep` is
    /// cancellation-aware and returns by throwing, which `try?` turns into a
    /// normal return.
    static func waitForTimeoutOrCancellation(_ timeout: TimeInterval?) async {
        let nanoseconds: UInt64
        if let timeout, timeout.isFinite, timeout > 0 {
            let maximumSleepSeconds = Double(UInt64.max) / 1_000_000_000
            if timeout >= maximumSleepSeconds {
                nanoseconds = UInt64.max
            } else {
                nanoseconds = UInt64(timeout * 1_000_000_000)
            }
        } else {
            nanoseconds = UInt64.max
        }
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    /// Escalates until the child is guaranteed to be signalled to death.
    /// Returns `true` once escalation completed, mirroring the runner's
    /// "termination was forced" outcome.
    @discardableResult
    static func escalate(
        _ process: Process,
        exitSignal: FeatureProcessExitSignal,
        grace: Duration = defaultGrace,
        reapBudget: Duration = defaultReapBudget
    ) async -> Bool {
        if !exitSignal.hasExited {
            send(SIGTERM, to: process)
        }

        if await waitForExit(exitSignal, within: grace) {
            return true
        }

        if !exitSignal.hasExited {
            send(SIGKILL, to: process)
        }
        // The exit monitor owns Linux reaping independently from Foundation's
        // shared manager run loop, so this wait remains bounded even when
        // another long-running Process has parked that manager.
        await reap(exitSignal, within: reapBudget)
        return true
    }

    /// Cancellation-aware bounded wait for a real exit. Returns `true` only when
    /// the exit was genuinely observed: a cancellation that broke the wait must
    /// fall through to the caller's SIGKILL fallback.
    static func waitForExit(
        _ exitSignal: FeatureProcessExitSignal,
        within budget: Duration
    ) async -> Bool {
        if exitSignal.hasExited {
            return true
        }

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask(name: "Feature process termination grace exit") {
                await exitSignal.wait()
                return true
            }

            group.addTask(name: "Feature process termination grace budget") {
                try? await Task.sleep(for: budget)
                return false
            }

            _ = await group.next()
            group.cancelAll()
            return exitSignal.hasExited
        }
    }

    /// Bounded poll for the exit of an already-killed child. Unlike
    /// `waitForExit`, this deliberately keeps polling under cancellation so a
    /// cancelled run still gives the monitor a chance to observe the reap; the
    /// deadline keeps the wait finite regardless.
    static func reap(
        _ exitSignal: FeatureProcessExitSignal,
        within budget: Duration
    ) async {
        let deadline = ContinuousClock.now.advanced(by: budget)
        while ContinuousClock.now < deadline, !exitSignal.hasExited {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func send(_ signal: Int32, to process: Process) {
        FeatureProcessTreeSupervisor.send(
            signal,
            to: process,
            processGroupLeader: FeatureProcessTreeSupervisor.isProcessGroupLeader(process)
        )
    }
}
