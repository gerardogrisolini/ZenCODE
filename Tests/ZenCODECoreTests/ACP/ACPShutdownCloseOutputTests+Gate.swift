//
//  ACPShutdownCloseOutputTests+Gate.swift
//  ZenCODE
//
//  The gate of the shutdown/close output tests, which pins a genuinely
//  suspending seam of the backend until the test opens it.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Gate that reports arrival, so a test can pin production code at an exact
/// suspension point and only then run the racing operation.
final class OutputFenceGate: Sendable {
    private struct State {
        var isOpen = false
        var arrivals = 0
        var waiters: [CheckedContinuation<Void, Never>] = []
        var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    var arrivals: Int {
        state.withLock { $0.arrivals }
    }

    func arriveAndWait() async {
        let pendingArrivals = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.arrivals += 1
            let pending = state.arrivalWaiters
            state.arrivalWaiters.removeAll()
            return pending
        }
        for waiter in pendingArrivals {
            waiter.resume()
        }
        if state.withLock({ $0.isOpen }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func waitUntilReached() async {
        if state.withLock({ $0.arrivals > 0 }) {
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.arrivals > 0 {
                    return true
                }
                state.arrivalWaiters.append(continuation)
                return false
            }
            if resumeNow {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            let pending = state.waiters
            state.waiters.removeAll()
            return pending
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
