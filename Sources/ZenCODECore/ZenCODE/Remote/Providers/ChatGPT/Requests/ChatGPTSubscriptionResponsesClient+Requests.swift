//
//  ChatGPTSubscriptionResponsesClient+Requests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation

extension ChatGPTSubscriptionResponsesClient {
    /// Exact server error emitted when a Responses WebSocket reaches its
    /// 60-minute connection limit. This is intentionally not a substring
    /// match: unrelated application failures must not become retryable.
    static let webSocketConnectionLimitErrorMessage =
        "Responses websocket connection limit reached (60 minutes). Create a new websocket connection to continue."

    /// Canonical transient backend failure shown by ChatGPT with a per-attempt
    /// request ID. Keep this match narrow: arbitrary `response.failed` events
    /// can describe invalid tool calls or requests that must not be replayed.
    private static let retryableRequestFailurePrefix =
        "an error occurred while processing your request."
    private static let retryableRequestFailureHint =
        "you can retry your request"
    private static let retryableRequestFailureHelpCenter = "help.openai.com"
    private static let retryableRequestFailureIDHint =
        "please include the request id "

    func request(
        for body: [String: Any],
        sessionID: String,
        threadID: String? = nil
    ) throws -> RemoteHTTPStreamingRequest {
        let resolvedThreadID = threadID?.nilIfBlank ?? sessionID
        return RemoteHTTPStreamingRequest(
            url: Self.codexResponsesURL(baseURL: baseURL),
            method: "POST",
            headers: [
                RemoteHTTPHeader(
                    name: "Authorization",
                    value: "Bearer \(credentials.accessToken)"
                ),
                RemoteHTTPHeader(
                    name: "chatgpt-account-id",
                    value: credentials.accountID
                ),
                RemoteHTTPHeader(name: "originator", value: "ZenCODE"),
                RemoteHTTPHeader(name: "Accept", value: "text/event-stream"),
                RemoteHTTPHeader(
                    name: "Content-Type",
                    value: "application/json"
                ),
                RemoteHTTPHeader(name: "session-id", value: sessionID),
                RemoteHTTPHeader(name: "thread-id", value: resolvedThreadID),
                RemoteHTTPHeader(
                    name: "x-client-request-id",
                    value: resolvedThreadID
                )
            ],
            body: try JSONValue(jsonObject: body).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
            ),
            timeout: .seconds(600)
        )
    }

    func webSocketRequest(
        sessionID: String,
        threadID: String? = nil
    ) -> RemoteWebSocketRequest {
        let resolvedThreadID = threadID?.nilIfBlank ?? sessionID
        return RemoteWebSocketRequest(
            url: Self.codexWebSocketURL(baseURL: baseURL),
            headers: [
                RemoteHTTPHeader(
                    name: "Authorization",
                    value: "Bearer \(credentials.accessToken)"
                ),
                RemoteHTTPHeader(
                    name: "chatgpt-account-id",
                    value: credentials.accountID
                ),
                RemoteHTTPHeader(name: "originator", value: "ZenCODE"),
                RemoteHTTPHeader(
                    name: "OpenAI-Beta",
                    value: Self.webSocketBetaHeader
                ),
                RemoteHTTPHeader(name: "session-id", value: sessionID),
                RemoteHTTPHeader(name: "thread-id", value: resolvedThreadID),
                RemoteHTTPHeader(
                    name: "x-client-request-id",
                    value: resolvedThreadID
                )
            ],
            timeout: .seconds(600)
        )
    }

    /// Prepends a "subscription resumes at <time>" message to the error output
    /// for usage-limit responses (HTTP 429), using the reset hint from the body
    /// (`resets_in_seconds`/`reset_after_seconds`) or the `retry-after` header.
    static func enrichedLimitOutput(
        status: Int,
        output: String,
        headers: RemoteHTTPHeaders = RemoteHTTPHeaders(),
        now: Date = Date()
    ) -> String {
        guard status == 429 || isUsageLimitOutput(output) else {
            return output
        }
        guard let resetDate = limitResetDate(
            output: output,
            headers: headers,
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
        headers: RemoteHTTPHeaders,
        now: Date = Date()
    ) -> Date? {
        if let seconds = resetSeconds(fromOutput: output),
           let date = SubscriptionLimitResetFormatter.resetDate(
               fromSecondsValue: seconds,
               now: now
           ) {
            return date
        }
        if let retryAfter = headers.firstValue(for: "retry-after")?
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

        if let error = error as? RemoteTransportError {
            switch error {
            case .timeout, .closed, .connectionFailure:
                return true
            case let .upgradeRejected(status, _):
                // Auth and rate-limit failures may recover after a token
                // refresh or a brief backoff. Every other HTTP status is a
                // permanent protocol error (e.g. 404, 400) and must not loop.
                return status == 401 || status == 403 || status == 429
            case .invalidURL,
                 .unsupportedScheme,
                 .invalidHTTPMethod,
                 .invalidHeader,
                 .invalidWebSocketFrameSize,
                 .shutdown,
                 .bodyAlreadyConsumed,
                 .concurrentBodyRead,
                 .concurrentWebSocketReceive,
                 .protocolViolation,
                 .tlsFailure:
                return false
            }
        }

        if RemoteProviderSessionCompatibility.isRetryableLegacyNetworkError(error) {
            return true
        }

        if let posixError = error as? POSIXError,
           isRetryablePOSIXCode(posixError.code) {
            return true
        }

        let nsError = error as NSError
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

    static func isRetryableRequestFailure(_ error: Error) -> Bool {
        guard let error = error as? RetryableBackendFailure else {
            return false
        }
        return isRetryableRequestFailureMessage(error.message)
    }

    static func isRetryableRequestFailureMessage(_ message: String) -> Bool {
        let normalizedMessage = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
        return normalizedMessage.hasPrefix(retryableRequestFailurePrefix)
            && normalizedMessage.contains(retryableRequestFailureHint)
            && normalizedMessage.contains(retryableRequestFailureHelpCenter)
            && normalizedMessage.contains(retryableRequestFailureIDHint)
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

    /// Retries only the canonical transient backend failure on the already-
    /// selected HTTP transport. Generic transport interruptions retain the
    /// generation runner's existing retry budget, while replay-unsafe output is
    /// never duplicated.
    static func shouldRetryHTTPFailure(
        _ error: Error,
        attempt: Int
    ) -> Bool {
        guard attempt >= 0,
              attempt < maxRetries,
              !isCancellationError(error),
              !(error is ReplayUnsafeStreamFailure) else {
            return false
        }
        return isRetryableRequestFailure(error)
    }

    static func shouldRetryWebSocketFailure(
        _ error: Error,
        receivedReplayUnsafeEvent: Bool,
        attempt: Int
    ) -> Bool {
        guard !receivedReplayUnsafeEvent,
              attempt >= 0,
              attempt < maxRetries,
              !isCancellationError(error) else {
            return false
        }
        if let transportError = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = transportError,
           status == 401 || status == 403 {
            // The outer generation client owns credential refresh. Repeating
            // the same upgrade with the same token only delays recovery.
            return false
        }
        return isRetryableTransportError(error)
    }

    /// Switches a logical session away from the WebSocket route when retrying
    /// that same route cannot improve the outcome. Canonical backend failures
    /// fall back immediately; transport failures retain their bounded WebSocket
    /// retry budget first. Auth/rate-limit upgrade failures stay on their
    /// dedicated refresh/backoff paths instead of being replayed over HTTP.
    static func shouldActivateHTTPFallback(
        _ error: Error,
        receivedReplayUnsafeEvent: Bool,
        attempt: Int
    ) -> Bool {
        guard !receivedReplayUnsafeEvent,
              attempt >= 0,
              !isCancellationError(error) else {
            return false
        }

        if isRetryableRequestFailure(error) {
            return true
        }

        if let transportError = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = transportError {
            return status == 426
        }

        guard attempt >= maxRetries else {
            return false
        }
        return isRetryableTransportError(error)
    }

    static func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? ChatGPTSubscriptionGenerationError,
           case .cancelled = error {
            return true
        }
        return RemoteProviderSessionCompatibility.isLegacyCancellationError(error)
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
