//
//  ChatGPTSubscriptionResponsesClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//
#if os(macOS)
import Foundation

public struct ChatGPTSubscriptionResponsesClient {
    public struct StreamCompletion: Sendable {
        public let responseID: String?
    }

    struct WebSocketLease {
        let sessionID: String
        let task: URLSessionWebSocketTask
        let isCached: Bool
        let isReused: Bool
    }

    private struct WebSocketFailure: Error {
        let underlying: Error
        let didReceiveReplayUnsafeEvents: Bool
    }

    private struct WebSocketIdleTimeoutError: LocalizedError {
        let timeoutNanoseconds: UInt64

        var errorDescription: String? {
            let seconds = timeoutNanoseconds / 1_000_000_000
            return "WebSocket idle timeout after \(seconds)s"
        }
    }

    public let credentials: CodexAgentCredentials
    public let baseURL: URL
    public let urlSession: URLSession
        public let webSocketPool: ChatGPTSubscriptionWebSocketPool
    public let usesWebSocketTransport: Bool


    static let maxRetries = 3
    static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000
    static let webSocketBetaHeader = "responses_websockets=2026-02-06"
    static let webSocketIdleTimeoutNanoseconds: UInt64? = nil

    public init(
        credentials: CodexAgentCredentials,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
                urlSession: URLSession = .shared,
        webSocketPool: ChatGPTSubscriptionWebSocketPool = ChatGPTSubscriptionWebSocketPool(),
        usesWebSocketTransport: Bool = true
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.webSocketPool = webSocketPool
        self.usesWebSocketTransport = usesWebSocketTransport
    }

    public func streamEvents(
        input: JSONValue,
        model: String,
        instructions: String,
        reasoningEffort: String?,
        textVerbosity: String,
        sessionID: String,
        cachedWebSocketInput: JSONValue? = nil,
        previousResponseID: String? = nil,
        allowsFreshWebSocketContinuation: Bool = false,
        toolPayloads: JSONValue = .array([]),
        maxOutputTokens: Int? = nil,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        let body = ChatGPTSubscriptionRequestBuilder.requestBody(
            input: input,
            model: model,
            instructions: instructions,
            reasoningEffort: reasoningEffort,
            textVerbosity: textVerbosity,
            sessionID: sessionID,
            toolPayloads: toolPayloads,
            maxOutputTokens: maxOutputTokens
        )

        if usesWebSocketTransport,
           !webSocketPool.isFallbackToSSEActive(sessionID: sessionID) {
            do {
                return try await streamEventsOverWebSocket(
                    body: body,
                    cachedInput: cachedWebSocketInput,
                    previousResponseID: previousResponseID,
                    allowsFreshContinuation: allowsFreshWebSocketContinuation,
                    sessionID: sessionID,
                    onEvent: onEvent
                )
            } catch is CancellationError {
                throw ChatGPTSubscriptionGenerationError.cancelled
            } catch let error as WebSocketFailure {
                if error.didReceiveReplayUnsafeEvents
                    || !Self.isRetryableTransportError(error.underlying) {
                    throw error.underlying
                }
                webSocketPool.activateSSEFallback(sessionID: sessionID)
            }
        }

        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()

            do {
                let request = try request(for: body, sessionID: sessionID)
                let (bytes, response) = try await urlSession.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw ChatGPTSubscriptionGenerationError.invalidResponse
                }
                guard (200..<300).contains(httpResponse.statusCode) else {
                    let output = try await Self.collectErrorBody(from: bytes)
                    if attempt < Self.maxRetries,
                       Self.isRetryable(status: httpResponse.statusCode, output: output) {
                        try await Self.sleepForRetry(attempt: attempt)
                        continue
                    }
                    throw ChatGPTSubscriptionGenerationError.http(
                        status: httpResponse.statusCode,
                        output: Self.enrichedLimitOutput(
                            status: httpResponse.statusCode,
                            output: output,
                            response: httpResponse
                        )
                    )
                }

                if let rateLimits = ChatGPTSubscriptionGenerationClient
                    .rateLimitsObject(fromHTTPResponse: httpResponse) {
                    try await onEvent(["rate_limits": rateLimits])
                }

                var eventName: String?
                var dataLines: [String] = []
                var responseID: String?

                func flushEvent() async throws {
                    guard !dataLines.isEmpty else {
                        eventName = nil
                        return
                    }
                    defer {
                        eventName = nil
                        dataLines.removeAll(keepingCapacity: true)
                    }

                    let payload = dataLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !payload.isEmpty, payload != "[DONE]" else {
                        return
                    }
                    guard let data = payload.data(using: .utf8) else {
                        return
                    }

                    let objects = try Self.decodedJSONObjectSequence(from: data)
                    guard !objects.isEmpty else {
                        return
                    }

                    for var object in objects {
                        if object["type"] == nil,
                           let eventName {
                            object["type"] = eventName
                        }
                        if responseID == nil {
                            responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object)
                        }
                        try await onEvent(object)
                    }
                }

                for try await rawLine in bytes.lines {
                    try Task.checkCancellation()
                    let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
                    if line.isEmpty {
                        try await flushEvent()
                        continue
                    }
                    guard !line.hasPrefix(":") else {
                        continue
                    }
                    if line.hasPrefix("event:") {
                        eventName = String(line.dropFirst("event:".count))
                            .trimmingCharacters(in: .whitespaces)
                        continue
                    }
                    if line.hasPrefix("data:") {
                        dataLines.append(
                            String(line.dropFirst("data:".count))
                                .trimmingCharacters(in: .whitespaces)
                        )
                    }
                }
                try await flushEvent()
                return StreamCompletion(responseID: responseID)
            } catch is CancellationError {
                throw ChatGPTSubscriptionGenerationError.cancelled
            } catch let error as ChatGPTSubscriptionGenerationError {
                throw error
            } catch {
                if attempt < Self.maxRetries, Self.isRetryable(error: error) {
                    try await Self.sleepForRetry(attempt: attempt)
                    continue
                }
                throw error
            }
        }

        throw ChatGPTSubscriptionGenerationError.invalidResponse
    }

    private func streamEventsOverWebSocket(
        body: [String: Any],
        cachedInput: JSONValue?,
        previousResponseID: String?,
        allowsFreshContinuation: Bool,
        sessionID: String,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        let request = webSocketRequest(sessionID: sessionID)
        let lease = webSocketPool.acquire(
            sessionID: sessionID,
            request: request,
            urlSession: urlSession
        )
        var keepConnection = false
        var didReceiveReplayUnsafeEvents = false
        var responseID: String?
        var didReceiveTerminalEvent = false

        defer {
            webSocketPool.release(
                lease,
                keepAlive: keepConnection && didReceiveTerminalEvent
            )
        }

        do {
            let payload = try JSONValue(
                jsonObject: Self.webSocketRequestPayload(
                    body: body,
                    cachedInput: cachedInput,
                    previousResponseID: previousResponseID,
                    useCachedContinuation: lease.isReused || allowsFreshContinuation
                )
            ).jsonData(
                outputFormatting: [.withoutEscapingSlashes]
            )
            guard let text = String(data: payload, encoding: .utf8) else {
                throw ChatGPTSubscriptionGenerationError.invalidResponse
            }
            try await lease.task.send(
                URLSessionWebSocketTask.Message.string(text)
            )

            while !didReceiveTerminalEvent {
                try Task.checkCancellation()
                let message = try await Self.receiveWebSocketMessage(
                    from: lease.task,
                    timeoutNanoseconds: Self.webSocketIdleTimeoutNanoseconds
                )
                guard let data = Self.webSocketData(from: message) else {
                    continue
                }
                let objects = try Self.decodedJSONObjectSequence(from: data)
                for object in objects {
                    if responseID == nil {
                        responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object)
                    }
                    if Self.isReplayUnsafeWebSocketEvent(object) {
                        didReceiveReplayUnsafeEvents = true
                    }
                    try await onEvent(object)
                    if Self.isTerminalEvent(object) {
                        didReceiveTerminalEvent = true
                    }
                }
            }

            keepConnection = true
            return StreamCompletion(responseID: responseID)
        } catch is CancellationError {
            throw ChatGPTSubscriptionGenerationError.cancelled
        } catch {
            throw WebSocketFailure(
                underlying: error,
                didReceiveReplayUnsafeEvents: didReceiveReplayUnsafeEvents
            )
        }
    }

    static func receiveWebSocketMessage(
        from task: URLSessionWebSocketTask,
        timeoutNanoseconds: UInt64?
    ) async throws -> URLSessionWebSocketTask.Message {
        guard let timeoutNanoseconds, timeoutNanoseconds > 0 else {
            return try await task.receive()
        }
        return try await withThrowingTaskGroup(
            of: URLSessionWebSocketTask.Message.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                task.cancel(with: .normalClosure, reason: nil)
                throw WebSocketIdleTimeoutError(
                    timeoutNanoseconds: timeoutNanoseconds
                )
            }

            do {
                guard let message = try await group.next() else {
                    throw ChatGPTSubscriptionGenerationError.invalidResponse
                }
                group.cancelAll()
                return message
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

}

#endif
