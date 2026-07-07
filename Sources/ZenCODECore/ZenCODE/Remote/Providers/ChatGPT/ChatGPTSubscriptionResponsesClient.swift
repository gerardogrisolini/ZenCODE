//
//  ChatGPTSubscriptionResponsesClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//

#if os(macOS)
import Foundation
import ToolCore

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
    }

    public let credentials: CodexAgentCredentials
    public let baseURL: URL
    public let urlSession: URLSession
        public let webSocketPool: ChatGPTSubscriptionWebSocketPool


    static let maxRetries = 3
    static let baseRetryDelayNanoseconds: UInt64 = 1_000_000_000
    static let webSocketBetaHeader = "responses_websockets=2026-02-06"
    static let webSocketIdleTimeoutNanoseconds: UInt64? = nil

    public init(
        credentials: CodexAgentCredentials,
        baseURL: URL = URL(string: "https://chatgpt.com/backend-api")!,
                urlSession: URLSession = .shared,
        webSocketPool: ChatGPTSubscriptionWebSocketPool = ChatGPTSubscriptionWebSocketPool()
    ) {
        self.credentials = credentials
        self.baseURL = baseURL
        self.urlSession = urlSession
        self.webSocketPool = webSocketPool
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
        while true {
            do {
                return try await streamEventsOverWebSocket(
                    body: body,
                    cachedInput: cachedWebSocketInput,
                    previousResponseID: previousResponseID,
                    allowsFreshContinuation: allowsFreshWebSocketContinuation,
                    sessionID: sessionID,
                    onEvent: onEvent
                )
            } catch let failure as WebSocketStreamFailure {
                guard !failure.receivedReplayUnsafeEvent,
                      Self.shouldRetryTransportError(
                          failure.underlying,
                          attempt: attempt
                      ) else {
                    throw failure.underlying
                }
                try await Self.sleepForRetry(attempt: attempt)
                attempt += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.shouldRetryTransportError(error, attempt: attempt) else {
                    throw error
                }
                try await Self.sleepForRetry(attempt: attempt)
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
            request: request,
            urlSession: urlSession
        )
        var keepConnection = false
        var responseID: String?
        var didReceiveTerminalEvent = false
        var didReceiveReplayUnsafeEvent = false

        defer {
            webSocketPool.release(
                lease,
                keepAlive: keepConnection && didReceiveTerminalEvent
            )
        }

        do {
            try await withTaskCancellationHandler {
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
                        if Self.isReplayUnsafeWebSocketEvent(object) {
                            didReceiveReplayUnsafeEvent = true
                        }
                        if responseID == nil {
                            responseID = ChatGPTSubscriptionGenerationClient.responseID(from: object)
                        }
                        try await onEvent(object)
                        if Self.isTerminalEvent(object) {
                            didReceiveTerminalEvent = true
                        }
                    }
                }
            } onCancel: {
                lease.task.cancel(with: .goingAway, reason: nil)
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
                receivedReplayUnsafeEvent: didReceiveReplayUnsafeEvent
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
