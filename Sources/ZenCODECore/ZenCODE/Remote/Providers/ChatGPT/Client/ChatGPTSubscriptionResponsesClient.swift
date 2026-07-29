//
//  ChatGPTSubscriptionResponsesClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import ToolCore

public struct ChatGPTSubscriptionResponsesClient: Sendable {
    public struct StreamCompletion: Sendable {
        public let responseID: String?
        public let didActivateHTTPFallback: Bool

        init(
            responseID: String?,
            didActivateHTTPFallback: Bool = false
        ) {
            self.responseID = responseID
            self.didActivateHTTPFallback = didActivateHTTPFallback
        }
    }

    typealias HTTPFallbackOverride = @Sendable (
        JSONValue,
        String
    ) async throws -> StreamCompletion

    struct WebSocketLease {
        let sessionID: String
        let task: any ChatGPTSubscriptionWebSocketTask
        let isCached: Bool
        let isReused: Bool
        /// Fences a late release from changing the ownership of a later lease
        /// that happens to reuse the same task.
        let leaseID: UInt64
    }

    private struct WebSocketIdleTimeoutError: LocalizedError {
        let timeoutNanoseconds: UInt64

        var errorDescription: String? {
            let seconds = timeoutNanoseconds / 1_000_000_000
            return "WebSocket idle timeout after \(seconds)s"
        }
    }

    private struct WebSocketStreamFailure: Error {
        let underlying: Error
        let receivedReplayUnsafeEvent: Bool
        /// True when the request frame carrying `previous_response_id` may have
        /// reached the server before the failure. A retry must then replay the
        /// full conversation: the server may have consumed or invalidated that
        /// continuation state, and re-sending it yields an invalid-response_id
        /// rejection.
        let didSendContinuationPayload: Bool
    }

    /// Preserves the replay boundary when a lower-level transport failure is
    /// returned to the generation runner. The localized description delegates
    /// to the original error so backend request IDs remain visible to users.
    struct ReplayUnsafeStreamFailure: LocalizedError {
        let underlying: Error

        var errorDescription: String? {
            underlying.localizedDescription
        }
    }

    /// Provenance-preserving representation of the canonical transient
    /// `server_error` emitted by the Responses backend. Text alone is not enough
    /// to make a callback or a different provider error retryable.
    struct RetryableBackendFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    public let credentials: CodexAgentCredentials
    public let baseURL: URL
    /// Historical session value retained for source compatibility. It does not
    /// select or execute WebSocket I/O.
    public let urlSession: RemoteProviderSession
    public let webSocketPool: ChatGPTSubscriptionWebSocketPool
    private let retrySleep: @Sendable (Int) async throws -> Void
    private let httpFallbackOverride: HTTPFallbackOverride?

    static let maxRetries = 3
    static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000
    static let webSocketBetaHeader = "responses_websockets=2026-02-06"
    static let webSocketIdleTimeoutNanoseconds: UInt64? = nil

    public init(
        credentials: CodexAgentCredentials,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
        /// Historical injection retained for source compatibility. WebSocket
        /// I/O is NIO-only.
        urlSession: RemoteProviderSession? = nil,
        webSocketPool: ChatGPTSubscriptionWebSocketPool =
            ChatGPTSubscriptionWebSocketPool()
    ) {
        self.init(
            credentials: credentials,
            baseURL: baseURL,
            urlSession: urlSession,
            webSocketPool: webSocketPool,
            retrySleep: { attempt in
                try await Self.sleepForRetry(attempt: attempt)
            }
        )
    }

    init(
        credentials: CodexAgentCredentials,
        baseURL: URL,
        urlSession: RemoteProviderSession? = nil,
        webSocketPool: ChatGPTSubscriptionWebSocketPool,
        retrySleep: @escaping @Sendable (Int) async throws -> Void,
        httpFallbackOverride: HTTPFallbackOverride? = nil
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.urlSession = urlSession
            ?? RemoteProviderSessionCompatibility.generationSession()
        self.webSocketPool = webSocketPool
        self.retrySleep = retrySleep
        self.httpFallbackOverride = httpFallbackOverride
    }

    public func streamEvents(
        input: JSONValue,
        model: String,
        instructions: String,
        reasoningEffort: String?,
        textVerbosity: String,
        sessionID: String,
        threadID: String? = nil,
        fallbackScopeID: String? = nil,
        promptCacheKey: String? = nil,
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
            promptCacheKey: promptCacheKey,
            toolPayloads: toolPayloads,
            maxOutputTokens: maxOutputTokens
        )

        let resolvedThreadID = threadID?.nilIfBlank ?? sessionID
        let resolvedFallbackScopeID = fallbackScopeID?.nilIfBlank
            ?? resolvedThreadID

        var attempt = 0
        var suppressContinuationReplay = false
        while true {
            try Task.checkCancellation()
            let acquisition = webSocketPool.acquire(
                sessionID: sessionID,
                request: webSocketRequest(
                    sessionID: sessionID,
                    threadID: resolvedThreadID
                ),
                fallbackScopeID: resolvedFallbackScopeID
            )
            let lease: WebSocketLease
            switch acquisition {
            case let .acquired(acquiredLease):
                lease = acquiredLease
            case .useHTTPFallback:
                return try await streamEventsOverHTTPWithRetry(
                    body: body,
                    sessionID: sessionID,
                    threadID: resolvedThreadID,
                    fallbackScopeID: resolvedFallbackScopeID,
                    didActivateHTTPFallback: false,
                    onEvent: onEvent
                )
            case .closed:
                throw CancellationError()
            }

            do {
                return try await streamEventsOverWebSocket(
                    body: body,
                    cachedInput: suppressContinuationReplay ? nil : cachedWebSocketInput,
                    previousResponseID: suppressContinuationReplay ? nil : previousResponseID,
                    allowsFreshContinuation: allowsFreshWebSocketContinuation,
                    lease: lease,
                    onEvent: onEvent
                )
            } catch let failure as WebSocketStreamFailure {
                if Self.shouldActivateHTTPFallback(
                    failure.underlying,
                    receivedReplayUnsafeEvent: failure.receivedReplayUnsafeEvent,
                    attempt: attempt
                ) {
                    let didActivateHTTPFallback = webSocketPool.activateHTTPFallback(
                        scopeID: resolvedFallbackScopeID
                    )
                    return try await streamEventsOverHTTPWithRetry(
                        body: body,
                        sessionID: sessionID,
                        threadID: resolvedThreadID,
                        fallbackScopeID: resolvedFallbackScopeID,
                        didActivateHTTPFallback: didActivateHTTPFallback,
                        onEvent: onEvent
                    )
                }
                guard Self.shouldRetryWebSocketFailure(
                    failure.underlying,
                    receivedReplayUnsafeEvent: failure.receivedReplayUnsafeEvent,
                    attempt: attempt
                ) else {
                    if failure.receivedReplayUnsafeEvent {
                        throw ReplayUnsafeStreamFailure(
                            underlying: failure.underlying
                        )
                    }
                    throw failure.underlying
                }
                if failure.didSendContinuationPayload {
                    // The failed attempt may have consumed the previous
                    // response state server-side. `body` always carries the
                    // full conversation input, so later attempts fall back to
                    // a complete replay instead of a stale previous_response_id.
                    suppressContinuationReplay = true
                }
                try await retrySleep(attempt)
                attempt += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.shouldRetryTransportError(error, attempt: attempt) else {
                    throw error
                }
                try await retrySleep(attempt)
                attempt += 1
            }
        }
    }

    private func streamEventsOverWebSocket(
        body: [String: Any],
        cachedInput: JSONValue?,
        previousResponseID: String?,
        allowsFreshContinuation: Bool,
        lease: WebSocketLease,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        var keepConnection = false
        var responseID: String?
        var didReceiveTerminalEvent = false
        var didReceiveReplayUnsafeEvent = false
        var didSendContinuationPayload = false

        defer {
            webSocketPool.release(
                lease,
                keepAlive: keepConnection && didReceiveTerminalEvent
            )
        }

        do {
            try await withTaskCancellationHandler {
                let payloadObject = Self.webSocketRequestPayload(
                    body: body,
                    cachedInput: cachedInput,
                    previousResponseID: previousResponseID,
                    useCachedContinuation: lease.isReused || allowsFreshContinuation
                )
                let includesContinuation =
                    payloadObject["previous_response_id"] != nil
                let payload = try JSONValue(
                    jsonObject: payloadObject
                ).jsonData(
                    outputFormatting: [.withoutEscapingSlashes]
                )
                guard let text = String(data: payload, encoding: .utf8) else {
                    throw ChatGPTSubscriptionGenerationError.invalidResponse
                }

                // Probe fresh and reused sockets: a pooled connection can die
                // between heartbeats, and this exposes it before the payload is
                // committed. The task awaits a matching pong, not just a write.
                try await webSocketPool.waitUntilReady(lease.task)

                // Conservatively record continuation delivery before the frame
                // goes out: a mid-send failure may still have delivered it.
                didSendContinuationPayload = includesContinuation
                try await lease.task.send(.text(text))

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
                            responseID = ChatGPTSubscriptionGenerationClient.responseID(
                                from: object
                            )
                        }
                        if let failure = Self.retryableBackendFailure(from: object) {
                            throw failure
                        }
                        if Self.isReplayUnsafeStreamEvent(object) {
                            didReceiveReplayUnsafeEvent = true
                        }
                        try await onEvent(object)
                        if Self.isTerminalEvent(object) {
                            didReceiveTerminalEvent = true
                        }
                    }
                }
            } onCancel: {
                lease.task.cancel(
                    with: ChatGPTSubscriptionWebSocketCloseCode.goingAway,
                    reason: nil
                )
            }

            keepConnection = true
            return StreamCompletion(responseID: responseID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Self.isCancellationError(error) || Task.isCancelled {
                throw CancellationError()
            }
            throw WebSocketStreamFailure(
                underlying: error,
                receivedReplayUnsafeEvent: didReceiveReplayUnsafeEvent,
                didSendContinuationPayload: didSendContinuationPayload
            )
        }
    }

    private func streamEventsOverHTTPWithRetry(
        body: [String: Any],
        sessionID: String,
        threadID: String,
        fallbackScopeID: String,
        didActivateHTTPFallback: Bool,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        var attempt = 0
        while true {
            guard !webSocketPool.isHTTPFallbackScopeClosed(
                scopeID: fallbackScopeID
            ) else {
                throw CancellationError()
            }

            do {
                return try await streamEventsOverHTTP(
                    body: body,
                    sessionID: sessionID,
                    threadID: threadID,
                    fallbackScopeID: fallbackScopeID,
                    didActivateHTTPFallback: didActivateHTTPFallback,
                    onEvent: onEvent
                )
            } catch {
                guard Self.shouldRetryHTTPFailure(error, attempt: attempt) else {
                    throw error
                }
                try await retrySleep(attempt)
                attempt += 1
            }
        }
    }

    private func streamEventsOverHTTP(
        body: [String: Any],
        sessionID: String,
        threadID: String,
        fallbackScopeID: String,
        didActivateHTTPFallback: Bool,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        if let httpFallbackOverride {
            let completion = try await httpFallbackOverride(
                JSONValue(jsonObject: body),
                sessionID
            )
            return StreamCompletion(
                responseID: completion.responseID,
                didActivateHTTPFallback: didActivateHTTPFallback
            )
        }

        let lease = try await webSocketPool.openHTTPStream(
            try request(
                for: body,
                sessionID: sessionID,
                threadID: threadID
            ),
            scopeID: fallbackScopeID
        )
        defer { webSocketPool.releaseHTTPStream(lease) }
        let response = lease.response
        guard (200..<300).contains(response.status) else {
            let output = try await RemoteStreamTransport.collectErrorBody(
                from: response.body
            )
            throw ChatGPTSubscriptionGenerationError.http(
                status: response.status,
                output: Self.enrichedLimitOutput(
                    status: response.status,
                    output: output,
                    headers: response.headers
                )
            )
        }

        var responseID: String?
        var didReceiveTerminalEvent = false
        var didReceiveReplayUnsafeEvent = false
        do {
            eventLoop: for try await event in response.body.sseEvents() {
                try Task.checkCancellation()
                let payload = event.data.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                if payload.isEmpty {
                    continue
                }
                if payload == "[DONE]" {
                    break
                }
                let objects = try Self.decodedJSONObjectSequence(
                    from: Data(payload.utf8)
                )
                for object in objects {
                    if responseID == nil {
                        responseID = ChatGPTSubscriptionGenerationClient.responseID(
                            from: object
                        )
                    }
                    if let failure = Self.retryableBackendFailure(from: object) {
                        throw failure
                    }
                    if Self.isReplayUnsafeStreamEvent(object) {
                        didReceiveReplayUnsafeEvent = true
                    }
                    try await onEvent(object)
                    if Self.isTerminalEvent(object) {
                        didReceiveTerminalEvent = true
                        break eventLoop
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if didReceiveReplayUnsafeEvent {
                throw ReplayUnsafeStreamFailure(underlying: error)
            }
            throw error
        }

        guard didReceiveTerminalEvent else {
            let error = ChatGPTSubscriptionGenerationError.invalidResponse
            if didReceiveReplayUnsafeEvent {
                throw ReplayUnsafeStreamFailure(underlying: error)
            }
            throw error
        }

        return StreamCompletion(
            responseID: responseID,
            didActivateHTTPFallback: didActivateHTTPFallback
        )
    }

    static func receiveWebSocketMessage(
        from task: any ChatGPTSubscriptionWebSocketTask,
        timeoutNanoseconds: UInt64?
    ) async throws -> ChatGPTSubscriptionWebSocketMessage {
        guard let timeoutNanoseconds, timeoutNanoseconds > 0 else {
            return try await task.receive()
        }
        return try await withThrowingTaskGroup(
            of: ChatGPTSubscriptionWebSocketMessage.self
        ) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                task.cancel(
                    with: ChatGPTSubscriptionWebSocketCloseCode.normalClosure,
                    reason: nil
                )
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

    static func webSocketData(
        from message: ChatGPTSubscriptionWebSocketMessage
    ) -> Data? {
        switch message {
        case let .binary(data):
            return data
        case let .text(text):
            return Data(text.utf8)
        }
    }
}
