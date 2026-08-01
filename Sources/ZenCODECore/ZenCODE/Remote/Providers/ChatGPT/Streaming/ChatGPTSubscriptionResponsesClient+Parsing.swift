//
//  ChatGPTSubscriptionResponsesClient+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import ToolCore

extension ChatGPTSubscriptionResponsesClient {
    /// Structured error identifiers Codex treats as retryable on the Responses
    /// WebSocket path. Matching identifiers (or a wrapped 5xx status) avoids
    /// relying on localized server text while keeping unrelated callback errors
    /// and invalid requests non-retryable.
    private static let retryableBackendErrorIdentifiers: Set<String> = [
        "previous_response_not_found",
        "rate_limit_exceeded",
        "server_error",
        "server_is_overloaded",
        "slow_down",
        "websocket_connection_limit_reached"
    ]

    /// `response.failed` is retryable by default in Codex after these terminal
    /// request failures have been classified. Keep the exclusions explicit so
    /// context, account, policy, and malformed-request failures still reach the
    /// generation layer instead of being replayed as transient outages.
    private static let nonRetryableResponseFailureIdentifiers: Set<String> = [
        "bio_policy",
        "context_length_exceeded",
        "cyber_policy",
        "insufficient_quota",
        "invalid_prompt",
        "invalid_request",
        "invalid_request_error",
        "usage_not_included"
    ]

    static func decodedJSONObjectSequence(from data: Data) throws -> [[String: Any]] {
        if isDoneMarker(data) {
            return []
        }

        if let value = try? JSONDecoder().decode(JSONValue.self, from: data),
           let jsonObject = value.objectValue {
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
                  let jsonObject = value.objectValue else {
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

    static func retryableBackendFailure(
        from object: [String: Any]
    ) -> RetryableBackendFailure? {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        let response = object["response"] as? [String: Any]
        let responseStatus = (response?["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let errorObject: [String: Any]?
        if normalizedType == "error" {
            errorObject = object["error"] as? [String: Any]
        } else if normalizedType == "response_failed" || responseStatus == "failed" {
            errorObject = response?["error"] as? [String: Any]
        } else {
            errorObject = nil
        }

        guard let errorObject else {
            return nil
        }
        let errorType = (errorObject["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let errorCode = (errorObject["code"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let identifiers = [errorType, errorCode].compactMap { $0 }
        let hasNonRetryableResponseFailureIdentifier = identifiers.contains {
            nonRetryableResponseFailureIdentifiers.contains($0)
        }
        // An explicit transient code wins over a generic error type such as
        // `invalid_request_error`; the exclusion set only controls the default
        // classification of otherwise-unidentified `response.failed` events.
        let hasRetryableIdentifier = identifiers.contains {
            retryableBackendErrorIdentifiers.contains($0)
        }
        let status = JSONValue.intValue(fromJSONObject:
            object["status"] ?? object["status_code"]
        )
        let hasRetryableStatus = normalizedType == "error"
            && status.map { (500...599).contains($0) } == true
        let isResponseFailure = normalizedType == "response_failed"
            || responseStatus == "failed"
        let hasRetryableResponseFailure = isResponseFailure
            && !hasNonRetryableResponseFailureIdentifier
        guard hasRetryableIdentifier
                || hasRetryableStatus
                || hasRetryableResponseFailure,
              let message = ChatGPTSubscriptionGenerationClient
                .responseErrorMessage(from: object) else {
            return nil
        }
        return RetryableBackendFailure(
            message: message,
            retryDelayNanoseconds: retryDelayNanoseconds(
                from: message,
                errorCode: errorCode
            )
        )
    }

    static func retryDelayNanoseconds(
        from message: String,
        errorCode: String?
    ) -> UInt64? {
        guard errorCode == "rate_limit_exceeded",
              let expression = try? NSRegularExpression(
                  pattern: #"\btry again in\s+([0-9]+(?:\.[0-9]+)?)\s*(ms|s|milliseconds?|seconds?)\b"#,
                  options: [.caseInsensitive]
              ) else {
            return nil
        }
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = expression.firstMatch(
            in: message,
            options: [],
            range: fullRange
        ),
        let valueRange = Range(match.range(at: 1), in: message),
        let unitRange = Range(match.range(at: 2), in: message),
        let value = Double(message[valueRange]),
        value.isFinite,
        value >= 0 else {
            return nil
        }

        let unit = message[unitRange].lowercased()
        let multiplier = unit == "ms" || unit.hasPrefix("millisecond")
            ? 1_000_000.0
            : 1_000_000_000.0
        let roundedNanoseconds = (value * multiplier).rounded()
        // `Double(UInt64.max)` rounds up to 2^64. A strict comparison on the
        // rounded value keeps the subsequent integer conversion in range.
        guard roundedNanoseconds.isFinite,
              roundedNanoseconds >= 0,
              roundedNanoseconds < Double(UInt64.max) else {
            return nil
        }
        return UInt64(roundedNanoseconds)
    }

    static func isReplayUnsafeStreamEvent(_ object: [String: Any]) -> Bool {
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
            "refusal",
            "response_cancelled",
            "response_completed",
            "response_done",
            "response_incomplete",
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
            "response_failed",
            "response_cancelled"
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
