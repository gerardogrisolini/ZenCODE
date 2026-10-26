//
//  DS4UTF8StreamDecoder.swift
//  ZenCODE
//
//  Streaming UTF-8 decoder for the DS4 emit callback: a token's raw bytes may
//  split a scalar across calls, so incomplete trailing bytes are held until the
//  next chunk. Ported from `DS4UTF8StreamDecoder` (commit abd128942,
//  Sources/zen/LocalDS4/DS4Runtime.swift).
//

struct DS4UTF8StreamDecoder: Sendable {
    private var pendingBytes: [UInt8] = []

    /// True while bytes of an incomplete scalar are held.
    var hasPendingBytes: Bool {
        !pendingBytes.isEmpty
    }

    mutating func consume(_ bytes: [UInt8]) -> String {
        bytes.withUnsafeBufferPointer { buffer in
            consume(buffer)
        }
    }

    mutating func consume(_ buffer: UnsafeBufferPointer<UInt8>) -> String {
        guard !buffer.isEmpty else {
            return ""
        }
        pendingBytes.append(contentsOf: buffer)
        return emitCompletePrefix()
    }

    /// Flushes the held bytes (invalid sequences become U+FFFD).
    mutating func finish() -> String {
        guard !pendingBytes.isEmpty else {
            return ""
        }
        defer {
            pendingBytes.removeAll(keepingCapacity: true)
        }
        return String(decoding: pendingBytes, as: UTF8.self)
    }

    /// Emits the longest valid prefix that leaves at most 3 trailing bytes (the
    /// tail of a scalar still being received). When no such prefix exists and
    /// more than 3 bytes are held, the bytes are invalid: flush them with
    /// replacements instead of buffering forever.
    private mutating func emitCompletePrefix() -> String {
        let maxSuffixLength = min(3, pendingBytes.count)
        for suffixLength in 0...maxSuffixLength {
            let prefixLength = pendingBytes.count - suffixLength
            guard prefixLength > 0 else {
                continue
            }
            if let text = String(validating: pendingBytes[..<prefixLength], as: UTF8.self) {
                pendingBytes.removeFirst(prefixLength)
                return text
            }
        }

        guard pendingBytes.count > 3 else {
            return ""
        }
        defer {
            pendingBytes.removeAll(keepingCapacity: true)
        }
        return String(decoding: pendingBytes, as: UTF8.self)
    }
}
