//
//  MCPTransportCodec.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated enum MCPTransportCodec {
    public static func frame(_ payload: Data) -> Data {
        var framedPayload = payload
        framedPayload.append(0x0A)
        return framedPayload
    }

    public static func nextMessageBody(from buffer: inout Data) -> Data? {
        if let contentLengthBody = extractContentLengthBody(from: &buffer) {
            return contentLengthBody
        }

        // If the stream starts with transport headers (possibly partial),
        // wait for the full header/body instead of treating header lines as NDJSON.
        if looksLikeHeaderPrefix(buffer) {
            return nil
        }

        if let lineDelimitedBody = extractLineDelimitedBody(from: &buffer) {
            return lineDelimitedBody
        }

        return extractUndelimitedJSONBody(from: &buffer)
    }

    private static func looksLikeHeaderPrefix(_ buffer: Data) -> Bool {
        guard !buffer.isEmpty else {
            return false
        }

        let probeData = buffer.prefix(160)
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

    private static func extractContentLengthBody(from buffer: inout Data) -> Data? {
        guard let headerRange = headerTerminatorRange(in: buffer) else {
            return nil
        }

        let headerData = buffer.subdata(in: buffer.startIndex ..< headerRange.lowerBound)
        guard let headers = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let contentLength = headers
            .split(whereSeparator: { $0.isNewline || $0 == "\n" })
            .compactMap { line -> Int? in
                let components = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard components.count == 2,
                      components[0].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("Content-Length") == .orderedSame else {
                    return nil
                }

                return Int(components[1].trimmingCharacters(in: .whitespaces))
            }
            .first

        guard let contentLength else {
            return nil
        }

        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + contentLength

        guard buffer.count >= bodyEnd else {
            return nil
        }

        let body = buffer.subdata(in: bodyStart ..< bodyEnd)
        buffer.removeSubrange(buffer.startIndex ..< bodyEnd)
        return body
    }

    private static func headerTerminatorRange(in buffer: Data) -> Range<Data.Index>? {
        let patterns = [
            Data("\n\n".utf8),
            Data("\n\n".utf8),
            Data("\n\n".utf8),
            Data("\n\n".utf8)
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

    private static func extractLineDelimitedBody(from buffer: inout Data) -> Data? {
        guard let newlineIndex = buffer.firstIndex(of: 0x0A) else {
            return nil
        }

        let lineRange = buffer.startIndex ..< newlineIndex
        var line = buffer.subdata(in: lineRange)
        buffer.removeSubrange(buffer.startIndex ... newlineIndex)

        if line.last == 0x0D {
            line.removeLast()
        }

        return line
    }

    private static func extractUndelimitedJSONBody(from buffer: inout Data) -> Data? {
        if let wholeBufferBody = extractWholeBufferJSONObjectIfComplete(from: &buffer) {
            return wholeBufferBody
        }

        guard !buffer.isEmpty else {
            return nil
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
