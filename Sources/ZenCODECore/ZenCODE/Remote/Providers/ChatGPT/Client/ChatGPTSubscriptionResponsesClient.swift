//
//  ChatGPTSubscriptionResponsesClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import ToolCore

public struct ChatGPTSubscriptionResponsesClient {
    public struct StreamCompletion: Sendable {
        public let responseID: String?
    }

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

    public let credentials: CodexAgentCredentials
    public let baseURL: URL
    /// Historical session value retained for source compatibility. It does not
    /// select or execute WebSocket I/O.
    public let urlSession: RemoteProviderSession
    public let webSocketPool: ChatGPTSubscriptionWebSocketPool
    private let retrySleep: @Sendable (Int) async throws -> Void

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
        retrySleep: @escaping @Sendable (Int) async throws -> Void
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.urlSession = urlSession
            ?? RemoteProviderSessionCompatibility.generationSession()
        self.webSocketPool = webSocketPool
        self.retrySleep = retrySleep
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

        var attempt = 0
        var suppressContinuationReplay = false
        while true {
            do {
                return try await streamEventsOverWebSocket(
                    body: body,
                    cachedInput: suppressContinuationReplay ? nil : cachedWebSocketInput,
                    previousResponseID: suppressContinuationReplay ? nil : previousResponseID,
                    allowsFreshContinuation: allowsFreshWebSocketContinuation,
                    sessionID: sessionID,
                    onEvent: onEvent
                )
            } catch let failure as WebSocketStreamFailure {
                guard Self.shouldRetryWebSocketFailure(
                    failure.underlying,
                    receivedReplayUnsafeEvent: failure.receivedReplayUnsafeEvent,
                    attempt: attempt
                ) else {
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
        sessionID: String,
        onEvent: ([String: Any]) async throws -> Void
    ) async throws -> StreamCompletion {
        let request = webSocketRequest(sessionID: sessionID)
        let lease = webSocketPool.acquire(
            sessionID: sessionID,
            request: request
        )
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
                        if Self.isReplayUnsafeWebSocketEvent(object) {
                            didReceiveReplayUnsafeEvent = true
                        }
                        if responseID == nil {
                            responseID = ChatGPTSubscriptionGenerationClient.responseID(
                                from: object
                            )
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
