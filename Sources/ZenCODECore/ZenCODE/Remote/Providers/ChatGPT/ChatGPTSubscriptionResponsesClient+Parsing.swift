//
//  ChatGPTSubscriptionResponsesClient+Parsing.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
extension ChatGPTSubscriptionResponsesClient {
    static func collectErrorBody(
        from bytes: URLSession.AsyncBytes,
        limit: Int = 64 * 1024
    ) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count >= limit {
                break
            }
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodedJSONObjectSequence(from data: Data) throws -> [[String: Any]] {
        if isDoneMarker(data) {
            return []
        }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let jsonObject = value.mlxObjectValue {
            return [jsonObject.mapValues(\.jsonObject)]
        }

        var buffer = data
        var objects: [[String: Any]] = []

        while true {
            trimLeadingWhitespaceAndNewlines(from: &buffer)
            if buffer.isEmpty || isDoneMarker(buffer) {
                break
            }

            guard let nextObjectData = extractNextJSONObject(from: &buffer) else {
                break
            }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: nextObjectData),
                  let jsonObject = value.mlxObjectValue else {
                continue
            }
            objects.append(jsonObject.mapValues(\.jsonObject))
        }

        if objects.isEmpty {
            _ = try JSONDecoder().decode(JSONValue.self, from: data)
        }
        return objects
    }

    static func extractNextJSONObject(from buffer: inout Data) -> Data? {
        trimLeadingWhitespaceAndNewlines(from: &buffer)
        guard !buffer.isEmpty else {
            return nil
        }

        var index = buffer.startIndex
        var startIndex: Data.Index?
        var braceDepth = 0
        var bracketDepth = 0
        var inString = false
        var isEscaped = false

        while index < buffer.endIndex {
            let byte = buffer[index]

            if startIndex == nil {
                if byte == 0x7B || byte == 0x5B {
                    startIndex = index
                    if byte == 0x7B {
                        braceDepth = 1
                    } else {
                        bracketDepth = 1
                    }
                }
                index = buffer.index(after: index)
                continue
            }

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B:
                    braceDepth += 1
                case 0x7D:
                    braceDepth -= 1
                case 0x5B:
                    bracketDepth += 1
                case 0x5D:
                    bracketDepth -= 1
                default:
                    break
                }

                if braceDepth == 0,
                   bracketDepth == 0,
                   let startIndex {
                    let endIndex = buffer.index(after: index)
                    let objectData = buffer.subdata(in: startIndex ..< endIndex)
                    buffer.removeSubrange(buffer.startIndex ..< endIndex)
                    return objectData
                }
            }

            index = buffer.index(after: index)
        }

        return nil
    }

    static func trimLeadingWhitespaceAndNewlines(from buffer: inout Data) {
        while let firstByte = buffer.first,
              firstByte == 0x20 || firstByte == 0x09 || firstByte == 0x0A || firstByte == 0x0D {
            buffer.removeFirst()
        }
    }

    static func isDoneMarker(_ data: Data) -> Bool {
        guard let payload = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return payload == "[DONE]"
    }

    static func webSocketData(
        from message: URLSessionWebSocketTask.Message
    ) -> Data? {
        switch message {
        case let .data(data):
            return data
        case let .string(text):
            return text.data(using: .utf8)
        @unknown default:
            return nil
        }
    }

    static func isReplayUnsafeWebSocketEvent(_ object: [String: Any]) -> Bool {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        guard !normalizedType.isEmpty else {
            return true
        }

        let replayUnsafeMarkers = [
            "agent_message",
            "content_part",
            "function_call",
            "item_completed",
            "item_done",
            "item_started",
            "output_item",
            "output_text",
            "raw_response_item",
            "reasoning",
            "tool_call"
        ]
        return replayUnsafeMarkers.contains { normalizedType.contains($0) }
    }

    static func isTerminalEvent(_ object: [String: Any]) -> Bool {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        if [
            "response_completed",
            "response_done",
            "response_incomplete",
            "response_failed"
        ].contains(normalizedType) {
            return true
        }

        guard let response = object["response"] as? [String: Any],
              let status = (response["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() else {
            return false
        }

        return [
            "completed",
            "incomplete",
            "failed",
            "cancelled"
        ].contains(status)
    }

    static func normalizedEventType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}
#endif
