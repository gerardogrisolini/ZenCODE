//
//  ACPError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

public struct ACPError: LocalizedError {
    public let code: Int
    public let message: String

    public var errorDescription: String? {
        message
    }

    public static func invalidParams(_ message: String) -> ACPError {
        ACPError(code: -32602, message: message)
    }

    public static func internalError(_ message: String) -> ACPError {
        ACPError(code: -32603, message: message)
    }
}

extension AsyncSequence where Element == UInt8 {
    public func collectString() async throws -> String {
        var data = Data()
        for try await byte in self {
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension FileHandle {
    public func writeString(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        TerminalOutputSynchronization.lock()
        defer {
            TerminalOutputSynchronization.unlock()
        }
        write(data)
    }
}

private enum TerminalOutputSynchronization {
    private static let outputLock = OSAllocatedUnfairLock()

    static func lock() {
        outputLock.lock()
    }

    static func unlock() {
        outputLock.unlock()
    }
}
