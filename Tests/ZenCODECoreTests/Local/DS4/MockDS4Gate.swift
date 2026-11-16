//
//  MockDS4Gate.swift
//  ZenCODE
//
//  One-shot async gate that lets DS4 tests hold a scripted generation open
//  until they release it.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// One-shot async gate: `wait()` suspends until `open()` (cancellable).
final class MockDS4Gate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    init(isOpen: Bool = false) {
        state.withLock { $0.isOpen = isOpen }
    }

    var isOpen: Bool {
        state.withLock { $0.isOpen }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters.removeAll() }
            return Array(state.waiters.values)
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async throws {
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool? = state.withLock { state in
                    if state.isOpen {
                        return true
                    }
                    if Task.isCancelled {
                        return false
                    }
                    state.waiters[id] = continuation
                    return nil
                }
                switch resumeNow {
                case .some(true): continuation.resume()
                case .some(false): continuation.resume(throwing: CancellationError())
                case .none: break
                }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
