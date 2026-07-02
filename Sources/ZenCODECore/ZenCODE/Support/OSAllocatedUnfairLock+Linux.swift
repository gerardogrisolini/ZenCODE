//
//  OSAllocatedUnfairLock+Linux.swift
//  ZenCODE
//
//  Created for Linux compatibility.
//

#if os(Linux)

import Synchronization

/// Linux compatibility shim for the subset of `OSAllocatedUnfairLock` used by ZenCODE.
///
/// Darwin provides `OSAllocatedUnfairLock` from the `os` module. The Swift Linux SDK does
/// not include that module, so keep call sites portable by backing the same API shape with
/// `Synchronization.Mutex` on Linux.
public final class OSAllocatedUnfairLock<State>: @unchecked Sendable {
    private let mutex: Mutex<State>

    public init(initialState: consuming sending State) {
        self.mutex = Mutex(initialState)
    }

    public func withLock<R>(
        _ body: (inout sending State) throws -> sending R
    ) rethrows -> sending R {
        try mutex.withLock(body)
    }
}

extension OSAllocatedUnfairLock where State == Void {
    public convenience init() {
        self.init(initialState: ())
    }

    public func withLock<R>(_ body: () throws -> sending R) rethrows -> sending R {
        try withLock { (_: inout sending Void) in
            try body()
        }
    }
}
#endif
