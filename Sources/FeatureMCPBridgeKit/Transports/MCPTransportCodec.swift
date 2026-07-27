//
//  MCPTransportCodec.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Errors produced while decoding the byte-oriented MCP transport framing.
/// They are deliberately separate from JSON-RPC errors: a malformed frame means
/// the stream can no longer be safely re-synchronized and must be closed.
public nonisolated enum MCPTransportCodecError: Error, Equatable, LocalizedError, Sendable {
    case malformedHeader
    case invalidContentLength
    case frameTooLarge(limit: Int)

    public var errorDescription: String? {
        switch self {
        case .malformedHeader:
            return "Malformed MCP transport header."
        case .invalidContentLength:
            return "Invalid MCP Content-Length header."
        case let .frameTooLarge(limit):
            return "MCP transport frame exceeds the \(limit)-byte limit."
        }
    }
}

/// The non-throwing state produced while incrementally parsing an MCP stream.
public nonisolated enum MCPTransportCodecResult: Sendable {
    case message(Data)
    case needMoreData
    case malformed(MCPTransportCodecError)
}

public nonisolated enum MCPTransportCodec {
    /// Upper bound for one complete JSON-RPC message and for undecoded stream
    /// residue. Keeping both bounded prevents peers from growing a process-wide
    /// buffer simply by never terminating a frame.
    public static let maxFrameBytes = 1_048_576
    /// Headers have no reason to approach a message-sized budget. This also
    /// bounds an incomplete `Content-Length` prefix before a terminator arrives.
    public static let maxHeaderBytes = 16_384

    public static func frame(_ payload: Data) -> Data {
        var framedPayload = payload
        framedPayload.append(0x0A)
        return framedPayload
    }

    /// Incrementally extracts one message, reports that more bytes are needed,
    /// or identifies framing that cannot safely be recovered from.
    public static func nextMessage(from buffer: inout Data) -> MCPTransportCodecResult {
        guard !buffer.isEmpty else {
            return .needMoreData
        }

        // A partial header must not be mistaken for NDJSON. Bound it while waiting
        // for its terminator, otherwise an attacker can hold the connection open
        // while continuously extending the header.
        if looksLikeHeaderPrefix(buffer) {
            if let headerRange = headerTerminatorRange(in: buffer) {
                return extractContentLengthBody(from: &buffer, headerRange: headerRange)
            }
            return buffer.count > maxHeaderBytes
                ? .malformed(.frameTooLarge(limit: maxHeaderBytes))
                : .needMoreData
        }

        if let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let lineRange = buffer.startIndex ..< newlineIndex
            guard lineRange.count <= maxFrameBytes else {
                return .malformed(.frameTooLarge(limit: maxFrameBytes))
            }
            var line = buffer.subdata(in: lineRange)
            buffer.removeSubrange(buffer.startIndex ... newlineIndex)
            if line.last == 0x0D {
                line.removeLast()
            }
            return .message(line)
        }

        guard buffer.count <= maxFrameBytes else {
            return .malformed(.frameTooLarge(limit: maxFrameBytes))
        }

        if let body = extractUndelimitedJSONBody(from: &buffer) {
            return .message(body)
        }
        return .needMoreData
    }

    /// Compatibility wrapper for existing callers. New transport code must use
    /// `nextMessage(from:)` so malformed framing closes the connection instead of
    /// being indistinguishable from an incomplete frame.
    public static func nextMessageBody(from buffer: inout Data) -> Data? {
        guard case let .message(body) = nextMessage(from: &buffer) else {
            return nil
        }
        return body
    }

    private static func looksLikeHeaderPrefix(_ buffer: Data) -> Bool {
        guard !buffer.isEmpty else {
            return false
        }

        let probeData = buffer.prefix(min(buffer.count, maxHeaderBytes))
        guard let probeString = String(data: probeData, encoding: .utf8) else {
            return false
        }

        let trimmedPrefix = probeString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrefix.isEmpty else {
            return false
        }

        if trimmedPrefix.first == "{" || trimmedPrefix.first == "[" {
            return false
        }

        let firstLine: String = {
            if let lineBreakRange = trimmedPrefix.rangeOfCharacter(from: .newlines) {
                return String(trimmedPrefix[..<lineBreakRange.lowerBound])
            }
            return trimmedPrefix
        }()

        guard let colonIndex = firstLine.firstIndex(of: ":") else {
            return false
        }

        let headerName = firstLine[..<colonIndex]
            .trimmingCharacters(in: .whitespaces)
        guard !headerName.isEmpty else {
            return false
        }

        return headerName.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) || scalar == UnicodeScalar("-")
        }
    }

    private static func extractContentLengthBody(
        from buffer: inout Data,
        headerRange: Range<Data.Index>
    ) -> MCPTransportCodecResult {
        guard headerRange.lowerBound <= maxHeaderBytes else {
            return .malformed(.frameTooLarge(limit: maxHeaderBytes))
        }

        let headerData = buffer.subdata(in: buffer.startIndex ..< headerRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return .malformed(.malformedHeader)
        }

        var contentLength: Int?
        for line in headers.split(whereSeparator: { $0.isNewline }) {
            let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard components.count == 2 else {
                continue
            }
            guard components[0].trimmingCharacters(in: .whitespaces)
                .caseInsensitiveCompare("Content-Length") == .orderedSame else {
                continue
            }

            let rawLength = components[1].trimmingCharacters(in: .whitespaces)
            guard !rawLength.isEmpty,
                  rawLength.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
                  let parsed = Int(rawLength) else {
                return .malformed(.invalidContentLength)
            }
            guard parsed <= maxFrameBytes else {
                return .malformed(.frameTooLarge(limit: maxFrameBytes))
            }
            guard contentLength == nil else {
                return .malformed(.malformedHeader)
            }
            contentLength = parsed
        }

        guard let contentLength else {
            return .malformed(.malformedHeader)
        }

        let bodyStart = headerRange.upperBound
        let (bodyEnd, overflow) = bodyStart.addingReportingOverflow(contentLength)
        guard !overflow else {
            return .malformed(.invalidContentLength)
        }
        guard buffer.count >= bodyEnd else {
            return .needMoreData
        }

        let body = buffer.subdata(in: bodyStart ..< bodyEnd)
        buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
        return .message(body)
    }

    private static func headerTerminatorRange(in buffer: Data) -> Range<Data.Index>? {
        let patterns = [
            Data("\r\n\r\n".utf8),
            Data("\n\n".utf8),
        ]

        var selectedRange: Range<Data.Index>?
        for pattern in patterns {
            guard let candidateRange = buffer.range(of: pattern) else {
                continue
            }

            if let currentRange = selectedRange {
                if candidateRange.lowerBound < currentRange.lowerBound {
                    selectedRange = candidateRange
                }
            } else {
                selectedRange = candidateRange
            }
        }

        return selectedRange
    }

    private static func extractUndelimitedJSONBody(from buffer: inout Data) -> Data? {
        if let wholeBufferBody = extractWholeBufferJSONObjectIfComplete(from: &buffer) {
            return wholeBufferBody
        }

        var start = buffer.startIndex
        while start < buffer.endIndex,
              CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(buffer[start])) {
            start = buffer.index(after: start)
        }

        guard start < buffer.endIndex else {
            return nil
        }

        let openingByte = buffer[start]
        guard openingByte == 0x7B || openingByte == 0x5B else { // { or [
            return nil
        }

        var braceDepth = 0
        var bracketDepth = 0
        var inString = false
        var isEscaped = false
        var index = start

        while index < buffer.endIndex {
            let byte = buffer[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C { // \
                    isEscaped = true
                } else if byte == 0x22 { // "
                    inString = false
                }
            } else {
                switch byte {
                case 0x22: // "
                    inString = true
                case 0x7B: // {
                    braceDepth += 1
                case 0x7D: // }
                    braceDepth -= 1
                case 0x5B: // [
                    bracketDepth += 1
                case 0x5D: // ]
                    bracketDepth -= 1
                default:
                    break
                }

                if braceDepth == 0, bracketDepth == 0 {
                    let endExclusive = buffer.index(after: index)
                    let body = buffer.subdata(in: start ..< endExclusive)
                    buffer.removeSubrange(buffer.startIndex ..< endExclusive)
                    return body
                }
            }

            index = buffer.index(after: index)
        }

        return nil
    }

    private static func extractWholeBufferJSONObjectIfComplete(from buffer: inout Data) -> Data? {
        guard let firstSignificantByte = firstNonWhitespaceByte(in: buffer),
              firstSignificantByte == 0x7B || firstSignificantByte == 0x5B else { // { or [
            return nil
        }

        guard (try? JSONDecoder().decode(JSONValue.self, from: buffer)) != nil else {
            return nil
        }

        let body = buffer
        buffer.removeAll(keepingCapacity: true)
        return body
    }

    private static func firstNonWhitespaceByte(in buffer: Data) -> UInt8? {
        for byte in buffer {
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                continue
            }
            return byte
        }
        return nil
    }
}
