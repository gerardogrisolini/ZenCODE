//
//  MCPHTTPTransportClient+EventStream.swift
//  ZenCODE
//
//  Reads the JSON-RPC message out of a `text/event-stream` response body.
//

import Foundation

#if os(macOS)
extension MCPHTTPTransportClient {
    /// The payload of the first event of `data` that carries one: its `data:`
    /// lines joined, `[DONE]` excluded.
    public nonisolated static func firstJSONEventPayload(in data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var eventLines: [String] = []

        func payload(from lines: [String]) -> Data? {
            let dataLines = lines.compactMap { line -> String? in
                guard line.hasPrefix("data:") else {
                    return nil
                }

                return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            }

            let joined = dataLines.joined(separator: "\n")
            guard !joined.isEmpty, joined != "[DONE]" else {
                return nil
            }

            return joined.data(using: .utf8)
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if rawLine.isEmpty {
                if let payload = payload(from: eventLines) {
                    return payload
                }
                eventLines.removeAll(keepingCapacity: true)
                continue
            }

            eventLines.append(rawLine)
        }

        return payload(from: eventLines)
    }
}
#endif
