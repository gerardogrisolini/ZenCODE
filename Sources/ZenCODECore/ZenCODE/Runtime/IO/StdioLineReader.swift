//
//  StdioLineReader.swift
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
import Synchronization

public final class StdioLineReader: Sendable {
    private let buffer = Mutex<[UInt8]>([])

    public init() {}

    public func readLine() -> String? {
        while true {
            // Cooperative cancellation: StdioLineReader is driven by a detached
            // task in the ACP launcher whose `onTermination` cancels this task.
            // `availableData` blocks indefinitely and would never observe that
            // cancellation, so poll with a short timeout instead and stop as
            // soon as the task is cancelled.
            if Task.isCancelled {
                return nil
            }
            if let line = takeBufferedLine() {
                return line
            }

            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, 200)
            if Task.isCancelled {
                return nil
            }
            if pollResult > 0, (descriptor.revents & Int16(POLLIN)) != 0 {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                    read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
                }
                if readCount <= 0 {
                    // EOF (0) or read error (-1): flush any buffered remainder.
                    return takeBufferedRemainder()
                }
                buffer.withLock { buffer in
                    buffer.append(contentsOf: Array(bytes.prefix(readCount)))
                }
            } else if pollResult == -1, errno != EINTR {
                return takeBufferedRemainder()
            }
        }
    }

    public func drainBufferedLines(waitMilliseconds: Int32 = 0) -> [String] {
        if waitMilliseconds > 0 {
            drainPendingInput(waitMilliseconds: waitMilliseconds)
        }

        return buffer.withLock { buffer in
            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0a) {
                let lineBytes = Array(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                lines.append(Self.string(fromLineBytes: lineBytes))
            }
            if !buffer.isEmpty {
                let lineBytes = buffer
                buffer.removeAll()
                lines.append(Self.string(fromLineBytes: lineBytes))
            }
            return lines
        }
    }

    private func takeBufferedLine() -> String? {
        buffer.withLock { buffer in
            guard let newlineIndex = buffer.firstIndex(of: 0x0a) else {
                return nil
            }
            let lineBytes = Array(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            return Self.string(fromLineBytes: lineBytes)
        }
    }

    private func takeBufferedRemainder() -> String? {
        buffer.withLock { buffer in
            guard !buffer.isEmpty else {
                return nil
            }
            let lineBytes = buffer
            buffer.removeAll()
            return Self.string(fromLineBytes: lineBytes)
        }
    }

    private func drainPendingInput(waitMilliseconds: Int32) {
        var timeout = waitMilliseconds
        while true {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, timeout)
            guard pollResult > 0,
                  (descriptor.revents & Int16(POLLIN)) != 0 else {
                return
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                read(STDIN_FILENO, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard readCount > 0 else {
                return
            }
            let chunk = Array(bytes.prefix(readCount))
            buffer.withLock { buffer in
                buffer.append(contentsOf: chunk)
            }
            timeout = 25
        }
    }

    private static func string(fromLineBytes bytes: [UInt8]) -> String {
        String(decoding: trimmedCarriageReturn(from: bytes), as: UTF8.self)
    }

    private static func trimmedCarriageReturn(from bytes: [UInt8]) -> [UInt8] {
        guard bytes.last == 0x0d else {
            return bytes
        }
        return Array(bytes.dropLast())
    }
}
