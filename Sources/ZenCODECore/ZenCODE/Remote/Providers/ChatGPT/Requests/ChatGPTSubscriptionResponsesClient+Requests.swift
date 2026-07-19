//
//  ChatGPTSubscriptionResponsesClient+Requests.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(macOS)
import Network

extension ChatGPTSubscriptionResponsesClient {
    /// Exact server error emitted when a Responses WebSocket reaches its
    /// 60-minute connection limit. This is intentionally not a substring
    /// match: unrelated application failures must not become retryable.
    static let webSocketConnectionLimitErrorMessage =
        "Responses websocket connection limit reached (60 minutes). Create a new websocket connection to continue."

    func request(
        for body: [String: Any],
        sessionID: String
    ) throws -> URLRequest {
        var request = URLRequest(url: Self.codexResponsesURL(baseURL: baseURL))
        request.httpMethod = "POST"
        request.httpBody = try JSONValue(jsonObject: body).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        request.timeoutInterval = 600
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.accountID,
            forHTTPHeaderField: "chatgpt-account-id"
        )
        request.setValue("ZenCODE", forHTTPHeaderField: "originator")
        request.setValue("responses=experimental", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(sessionID, forHTTPHeaderField: "session_id")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        return request
    }

    func webSocketRequest(sessionID: String) -> URLRequest {
        var request = URLRequest(url: Self.codexWebSocketURL(baseURL: baseURL))
        request.timeoutInterval = 600
        request.setValue(
            "Bearer \(credentials.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            credentials.accountID,
            forHTTPHeaderField: "chatgpt-account-id"
        )
        request.setValue("ZenCODE", forHTTPHeaderField: "originator")
        request.setValue(
            Self.webSocketBetaHeader,
            forHTTPHeaderField: "OpenAI-Beta"
        )
        request.setValue(sessionID, forHTTPHeaderField: "session-id")
        request.setValue(sessionID, forHTTPHeaderField: "x-client-request-id")
        return request
    }

    /// Prepends a "subscription resumes at <time>" message to the error output
    /// for usage-limit responses (HTTP 429), using the reset hint from the body
    /// (`resets_in_seconds`/`reset_after_seconds`) or the `retry-after` header.
    static func enrichedLimitOutput(
        status: Int,
        output: String,
        response: HTTPURLResponse,
        now: Date = Date()
    ) -> String {
        guard status == 429 || isUsageLimitOutput(output) else {
            return output
        }
        guard let resetDate = limitResetDate(
            output: output,
            response: response,
            now: now
        ) else {
            return output
        }
        let message = SubscriptionLimitResetFormatter.limitReachedMessage(
            provider: "ChatGPT",
            resetDate: resetDate,
            now: now
        )
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedOutput.isEmpty ? message : "\(message) \(trimmedOutput)"
    }

    static func isUsageLimitOutput(_ output: String) -> Bool {
        let normalized = output.lowercased()
        return normalized.contains("usage limit")
            || normalized.contains("rate limit")
            || normalized.contains("quota")
    }

    static func limitResetDate(
        output: String,
        response: HTTPURLResponse,
        now: Date = Date()
    ) -> Date? {
        if let seconds = resetSeconds(fromOutput: output),
           let date = SubscriptionLimitResetFormatter.resetDate(
               fromSecondsValue: seconds,
               now: now
           ) {
            return date
        }
        if let retryAfter = response.value(forHTTPHeaderField: "retry-after")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !retryAfter.isEmpty,
           let date = SubscriptionLimitResetFormatter.resetDate(
               fromRetryAfterHeader: retryAfter,
               now: now
           ) {
            return date
        }
        return nil
    }

    static func resetSeconds(fromOutput output: String) -> Double? {
        guard let data = output.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            return nil
        }
        let jsonObject = object.mapValues(\.jsonObject)
        let candidates: [[String: Any]] = [
            jsonObject,
            jsonObject["error"] as? [String: Any] ?? [:],
            jsonObject["rate_limits"] as? [String: Any] ?? [:]
        ]
        let keys = [
            "resets_in_seconds",
            "resetsInSeconds",
            "reset_after_seconds",
            "resetAfterSeconds",
            "reset_after",
            "retry_after",
            "retryAfter"
        ]
        for candidate in candidates {
            for key in keys {
                if let seconds = JSONValue(jsonObject: candidate[key]).doubleValue {
                    return seconds
                }
            }
        }
        return nil
    }

    static func isRetryable(
        status: Int,
        output: String
    ) -> Bool {
        if [429, 500, 502, 503, 504].contains(status) {
            return true
        }
        let normalizedOutput = output.lowercased()
        return normalizedOutput.contains("rate limit")
            || normalizedOutput.contains("overloaded")
            || normalizedOutput.contains("service unavailable")
            || normalizedOutput.contains("upstream connect")
            || normalizedOutput.contains("connection refused")
    }

    static func isRetryableTransportError(_ error: Error) -> Bool {
        if isWebSocketConnectionLimitError(error) {
            return true
        }

        if let urlError = error as? URLError,
           isRetryableURLCode(urlError.code) {
            return true
        }

        if let posixError = error as? POSIXError,
           isRetryablePOSIXCode(posixError.code) {
            return true
        }

        if let networkError = error as? NWError,
           case let .posix(code) = networkError,
           isRetryablePOSIXCode(code) {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           isRetryableURLCode(URLError.Code(rawValue: nsError.code)) {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain,
           isRetryablePOSIXCode(POSIXErrorCode(rawValue: Int32(nsError.code))) {
            return true
        }

        let localizedDescription = nsError.localizedDescription
        return localizedDescription
            .localizedCaseInsensitiveContains("socket is not connected")
            || localizedDescription
            .localizedCaseInsensitiveContains("socket is closed")
    }

    static func isWebSocketConnectionLimitError(_ error: Error) -> Bool {
        guard let error = error as? ChatGPTSubscriptionGenerationError,
              case let .responseFailed(message) = error else {
            return false
        }
        return isWebSocketConnectionLimitMessage(message)
    }

    static func isWebSocketConnectionLimitMessage(_ message: String) -> Bool {
        message
            .localizedCaseInsensitiveCompare(webSocketConnectionLimitErrorMessage)
            == .orderedSame
    }

    static func isRetryable(error: Error) -> Bool {
        isRetryableTransportError(error)
    }

    static func shouldRetryTransportError(
        _ error: Error,
        attempt: Int
    ) -> Bool {
        guard attempt >= 0, attempt < maxRetries else {
            return false
        }
        if isCancellationError(error) {
            return false
        }
        return isRetryableTransportError(error)
    }

    static func shouldRetryWebSocketFailure(
        _ error: Error,
        receivedReplayUnsafeEvent: Bool,
        attempt: Int
    ) -> Bool {
        guard !receivedReplayUnsafeEvent else {
            return false
        }
        return shouldRetryTransportError(error, attempt: attempt)
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? ChatGPTSubscriptionGenerationError,
           case .cancelled = error {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == URLError.cancelled.rawValue
    }

    static func isRetryableURLCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    static func isRetryablePOSIXCode(_ code: POSIXErrorCode?) -> Bool {
        switch code {
        case .ENOTCONN,
             .ECONNRESET,
             .ECONNABORTED,
             .ETIMEDOUT,
             .EPIPE,
             .ENETDOWN,
             .ENETUNREACH,
             .EHOSTUNREACH:
            return true
        default:
            return false
        }
    }

    static func sleepForRetry(attempt: Int) async throws {
        let multiplier = UInt64(max(1, 1 << attempt))
        try await Task.sleep(
            nanoseconds: baseRetryDelayNanoseconds * multiplier
        )
    }

    static func codexResponsesURL(baseURL: URL) -> URL {
        var value = baseURL.absoluteString
        while value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix("/codex/responses") {
            return URL(string: value)!
        }
        if value.hasSuffix("/codex") {
            return URL(string: "\(value)/responses")!
        }
        return URL(string: "\(value)/codex/responses")!
    }

    public static func codexWebSocketURL(baseURL: URL) -> URL {
        guard var components = URLComponents(
            url: codexResponsesURL(baseURL: baseURL),
            resolvingAgainstBaseURL: false
        ) else {
            return codexResponsesURL(baseURL: baseURL)
        }

        switch components.scheme?.lowercased() {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        default:
            break
        }
        return components.url ?? codexResponsesURL(baseURL: baseURL)
    }

    static func continuationRequestPayload(
        body: [String: Any],
        cachedInput: JSONValue? = nil,
        previousResponseID: String? = nil,
        useContinuation: Bool = false
    ) -> [String: Any] {
        var payload = body
        if useContinuation,
           let previousResponseID = previousResponseID?.nilIfBlank,
           let cachedInput {
            payload["previous_response_id"] = previousResponseID
            payload["input"] = cachedInput.acpJSONObject
        }
        return payload
    }

    static func webSocketRequestPayload(
        body: [String: Any],
        cachedInput: JSONValue? = nil,
        previousResponseID: String? = nil,
        useCachedContinuation: Bool = false
    ) -> [String: Any] {
        var payload = continuationRequestPayload(
            body: body,
            cachedInput: cachedInput,
            previousResponseID: previousResponseID,
            useContinuation: useCachedContinuation
        )
        payload["type"] = "response.create"
        return payload
    }
}
#endif
