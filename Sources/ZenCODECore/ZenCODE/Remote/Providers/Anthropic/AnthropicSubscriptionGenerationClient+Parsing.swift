//
//  AnthropicSubscriptionGenerationClient+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AnthropicSubscriptionGenerationClient {
    static func contentBlockText(from object: [String: Any]) -> String? {
        guard let contentBlock = object["content_block"] as? [String: Any],
              stringValue(contentBlock["type"])?.lowercased() == "text" else {
            return nil
        }
        return stringValue(contentBlock["text"])
    }

    static func usage(from value: Any?, previous: RemoteGenerationUsage? = nil) -> RemoteGenerationUsage? {
        AnthropicSubscriptionRequestBuilder.usage(
            from: value,
            previous: previous
        )
    }

    static func errorMessage(from object: [String: Any]) -> String? {
        if let error = object["error"] as? [String: Any] {
            return stringValue(error["message"])
                ?? stringValue(error["type"])
        }
        return stringValue(object["message"])
    }

    static func validateHTTPResponse(
        _ response: URLResponse,
        bytes: URLSession.AsyncBytes
    ) async throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            return
        }
        guard !(200..<300).contains(httpResponse.statusCode) else {
            return
        }

        let body = try await collectErrorBody(from: bytes)
        var details: [String] = []
        if httpResponse.statusCode == 429,
           let resumeMessage = limitReachedMessage(fromHTTPResponse: httpResponse) {
            details.append(resumeMessage)
        }
        if let message = errorMessage(fromJSONString: body)?.nilIfBlank {
            details.append(message)
        }
        if let retryAfter = httpResponse.value(forHTTPHeaderField: "retry-after")?.nilIfBlank {
            details.append("retry-after=\(retryAfter)")
        }
        if let requestID = httpResponse.value(forHTTPHeaderField: "request-id")?.nilIfBlank
            ?? httpResponse.value(forHTTPHeaderField: "x-request-id")?.nilIfBlank {
            details.append("request-id=\(requestID)")
        }
        let bodyDetail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if details.isEmpty, !bodyDetail.isEmpty {
            details.append(bodyDetail)
        }

        let suffix = details.isEmpty ? "" : ": \(details.joined(separator: "; "))"
        throw RemoteGenerationClientError.remoteFailure(
            "Anthropic Subscription returned HTTP \(httpResponse.statusCode)\(suffix)"
        )
    }

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
    }

    static func errorMessage(fromJSONString string: String) -> String? {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return nil
        }
        let jsonObject = object.mapValues(\.jsonObject)
        if let error = jsonObject["error"] as? [String: Any] {
            let type = stringValue(error["type"])?.nilIfBlank
            let message = stringValue(error["message"])?.nilIfBlank
            return [type, message].compactMap { $0 }.joined(separator: ": ").nilIfBlank
        }
        return stringValue(jsonObject["message"])?.nilIfBlank
            ?? stringValue(jsonObject["type"])?.nilIfBlank
    }

    static func jsonObject(fromJSONString string: String) -> [String: Any] {
        guard let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return [:]
        }
        return object.mapValues(\.jsonObject)
    }

    /// Extracts subscription usage from the `anthropic-ratelimit-unified-*` response headers.
    /// The 5h window maps to the daily usage and the 7d window maps to the weekly usage.
    static func subscriptionUsage(
        fromHTTPResponse response: URLResponse
    ) -> DirectAgentSubscriptionUsageStatus? {
        guard let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        let dailyUsedPercent = headerDouble(
            in: httpResponse,
            keys: [
                "anthropic-ratelimit-unified-5h-utilization",
                "anthropic-ratelimit-unified-5h-used-percent"
            ]
        )
        let weeklyUsedPercent = headerDouble(
            in: httpResponse,
            keys: [
                "anthropic-ratelimit-unified-7d-utilization",
                "anthropic-ratelimit-unified-7d-used-percent"
            ]
        )
        let dailyResetsInSeconds = headerResetSeconds(
            in: httpResponse,
            keys: ["anthropic-ratelimit-unified-5h-reset"]
        )
        let weeklyResetsInSeconds = headerResetSeconds(
            in: httpResponse,
            keys: ["anthropic-ratelimit-unified-7d-reset"]
        )
        guard dailyUsedPercent != nil || weeklyUsedPercent != nil else {
            return nil
        }
        return DirectAgentSubscriptionUsageStatus(
            provider: "Anthropic",
            dailyUsedPercent: dailyUsedPercent,
            weeklyUsedPercent: weeklyUsedPercent,
            dailyResetsInSeconds: dailyResetsInSeconds,
            weeklyResetsInSeconds: weeklyResetsInSeconds
        )
    }

    private static func headerDouble(
        in response: HTTPURLResponse,
        keys: [String]
    ) -> Double? {
        for key in keys {
            guard let raw = response.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            let normalized = raw.hasSuffix("%") ? String(raw.dropLast()) : raw
            if let value = Double(normalized.trimmingCharacters(in: .whitespacesAndNewlines)) {
                // Utilization headers are fractions in [0, 1]; convert to a percentage.
                return value <= 1.0 ? value * 100 : value
            }
        }
        return nil
    }

    /// Builds the "subscription resumes at <time>" message for a 429 response,
    /// using the soonest reset hint available across the rate-limit headers.
    static func limitReachedMessage(
        fromHTTPResponse response: HTTPURLResponse,
        now: Date = Date()
    ) -> String? {
        var resetDates: [Date] = []
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !retryAfter.isEmpty,
           let date = SubscriptionLimitResetFormatter.resetDate(
               fromRetryAfterHeader: retryAfter,
               now: now
           ) {
            resetDates.append(date)
        }
        for key in [
            "anthropic-ratelimit-unified-5h-reset",
            "anthropic-ratelimit-unified-7d-reset",
            "anthropic-ratelimit-unified-reset"
        ] {
            guard let raw = response.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            if let seconds = Double(raw),
               let date = SubscriptionLimitResetFormatter.resetDate(
                   fromSecondsValue: seconds,
                   now: now
               ) {
                resetDates.append(date)
            } else if let date = sharedISO8601Formatter.date(from: raw) {
                resetDates.append(date)
            }
        }
        guard let soonestReset = resetDates.min() else {
            return nil
        }
        return SubscriptionLimitResetFormatter.limitReachedMessage(
            provider: "Anthropic",
            resetDate: soonestReset,
            now: now
        )
    }

    private static func headerResetSeconds(
        in response: HTTPURLResponse,
        keys: [String]
    ) -> Int? {
        for key in keys {
            guard let raw = response.value(forHTTPHeaderField: key)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                continue
            }
            // The reset header may be a unix timestamp or a relative seconds value.
            if let absolute = Double(raw) {
                if absolute > 1_000_000_000 {
                    let delta = absolute - Date().timeIntervalSince1970
                    return delta > 0 ? Int(delta) : 0
                }
                return Int(max(absolute, 0))
            }
            if let date = sharedISO8601Formatter.date(from: raw) {
                let delta = date.timeIntervalSinceNow
                return delta > 0 ? Int(delta) : 0
            }
        }
        return nil
    }

    /// `ISO8601DateFormatter` is expensive to initialize and its `date(from:)`
    /// parsing is thread-safe for read-only use, so reuse a single instance.
    private nonisolated(unsafe) static let sharedISO8601Formatter = ISO8601DateFormatter()

    static func stringValue(_ value: Any?) -> String? {
        RemoteGenerationClient.stringValue(value)
    }

    static func intValue(_ value: Any?) -> Int? {
        JSONValue(jsonObject: value).intValue
    }
}
#endif
