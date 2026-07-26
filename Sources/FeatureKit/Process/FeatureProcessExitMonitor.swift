//
//  FeatureProcessExitMonitor.swift
//  ZenCODE
//

import Foundation
import Synchronization

#if os(Linux)
import Glibc
#endif

/// Reports a `Process` exit exactly once without relying solely on Foundation's
/// termination callback.
///
/// `swift-corelibs-foundation` services process exits on a shared run-loop
/// thread. On Linux, one long-running child can keep that thread inside
/// `waitpid(pid, 0)` and delay every later `terminationHandler`. The Linux
/// fallback below polls this monitor's own child with `waitpid(pid, WNOHANG)`,
/// preserving asynchronous progress even while Foundation's manager is parked.
public final class FeatureProcessExitMonitor: Sendable {
    public typealias Completion = @Sendable (_ exitCode: Int32) -> Void

    private struct State: Sendable {
        var exitCode: Int32?
        var didStart = false
        var didDeliver = false
    }

    private let state = Mutex(State())
    private let completion: Completion

    public init(completion: @escaping Completion) {
        self.completion = completion
    }

    /// Installs the ordinary Foundation completion path. Call before
    /// `Process.run()` so a very short-lived child cannot finish unobserved.
    public func install(on process: Process) {
        process.terminationHandler = { [self] process in
            complete(exitCode: process.terminationStatus)
        }
    }

    /// Activates delivery after the owner has published all state associated
    /// with the launched process. A result received between `run()` and this
    /// call is retained and delivered here rather than being lost.
    public func startMonitoring(processID: Int32) {
        let action = state.withLock { state -> (exitCode: Int32?, shouldMonitor: Bool) in
            guard !state.didStart else {
                return (nil, false)
            }
            state.didStart = true
            if let exitCode = state.exitCode {
                state.didDeliver = true
                return (exitCode, false)
            }
            return (nil, true)
        }

        if let exitCode = action.exitCode {
            completion(exitCode)
            return
        }

        #if os(Linux)
        if action.shouldMonitor, processID > 0 {
            Task.detached(priority: .utility) { [self] in
                await monitorLinuxProcess(processID)
            }
        }
        #else
        _ = action.shouldMonitor
        _ = processID
        #endif
    }

    private func complete(exitCode: Int32) {
        let shouldDeliver = state.withLock { state -> Bool in
            guard state.exitCode == nil else {
                return false
            }
            state.exitCode = exitCode
            guard state.didStart, !state.didDeliver else {
                return false
            }
            state.didDeliver = true
            return true
        }
        if shouldDeliver {
            completion(exitCode)
        }
    }

    #if os(Linux)
    private func monitorLinuxProcess(_ processID: Int32) async {
        while state.withLock({ $0.exitCode == nil }) {
            var status: Int32 = 0
            let result = waitpid(processID, &status, WNOHANG)

            if result == processID {
                complete(exitCode: Self.exitCode(fromWaitStatus: status))
                return
            }

            if result == -1 {
                let waitError = errno
                if waitError == EINTR {
                    continue
                }
                if waitError == ECHILD {
                    // Foundation won the waitpid race. Its handler runs directly
                    // after recording the status; allow that normal path a short
                    // bounded window to publish the exact exit code.
                    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
                    while ContinuousClock.now < deadline,
                          state.withLock({ $0.exitCode == nil }) {
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                    if state.withLock({ $0.exitCode == nil }) {
                        complete(exitCode: -1)
                    }
                } else {
                    complete(exitCode: -1)
                }
                return
            }

            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let lowBits = status & 0x7f
        if lowBits == 0 {
            return (status >> 8) & 0xff
        }
        if lowBits != 0x7f {
            return lowBits
        }
        return -1
    }
    #endif
}
