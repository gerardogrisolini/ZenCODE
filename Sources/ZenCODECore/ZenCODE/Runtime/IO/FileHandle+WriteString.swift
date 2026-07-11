//
//  FileHandle+WriteString.swift
//  ZenCODE
//

import Foundation
import Synchronization

extension FileHandle {
    public func writeString(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        TerminalOutputSynchronization.withLock {
            write(data)
        }
    }
}

private enum TerminalOutputSynchronization {
    private static let outputLock = Mutex(())

    static func withLock(_ body: @Sendable () -> Void) {
        outputLock.withLock { _ in
            body()
        }
    }
}
