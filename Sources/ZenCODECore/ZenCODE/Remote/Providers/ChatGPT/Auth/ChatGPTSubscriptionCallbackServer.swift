//
//  ChatGPTSubscriptionCallbackServer.swift
//  ZenCODE
//

import Foundation
#if os(macOS)
import Network
#endif
#if canImport(os)
import os
#endif

#if os(macOS)
final class ChatGPTSubscriptionCallbackServer: @unchecked Sendable {
    let state: String
    let queue = DispatchQueue(label: "ZenCODE.ChatGPTSubscriptionCallback")
    private let callbackState = ChatGPTSubscriptionCallbackServerState()

    init(state: String) {
        self.state = state
    }

    func start() async -> ChatGPTSubscriptionCallbackServer {
        guard let listener = try? NWListener(using: .tcp, on: 1455) else {
            return self
        }

        await callbackState.setListener(listener)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        do {
            try await startListening(listener)
        } catch {
            listener.cancel()
            await callbackState.clearListener(listener)
        }

        return self
    }

    func submitAuthorizationInput(_ input: String) throws {
        let code = try authorizationCode(fromAuthorizationInput: input)
        complete(.success(code))
    }

    func authorizationCode(fromAuthorizationInput input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        if let url = URL(string: value),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.queryItems?.contains(where: { $0.name == "code" }) == true {
            return try authorizationCode(from: components, requireState: false)
        }

        if value.contains("#") {
            let parts = value.split(separator: "#", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                guard parts[1] == state else {
                    throw ChatGPTSubscriptionAuthError.stateMismatch
                }
                let code = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else {
                    throw ChatGPTSubscriptionAuthError.missingAuthorizationCode
                }
                return code
            }
        }

        if value.contains("code=") {
            let query = value.hasPrefix("?") ? String(value.dropFirst()) : value
            if let components = URLComponents(string: "http://localhost/auth/callback?\(query)"),
               components.queryItems?.contains(where: { $0.name == "code" }) == true {
                return try authorizationCode(from: components, requireState: false)
            }
        }

        return value
    }

    func authorizationCode(
        from components: URLComponents,
        requireState: Bool
    ) throws -> String {
        let queryItems = components.queryItems ?? []
        let returnedState = queryItems.first(where: { $0.name == "state" })?.value
        if let returnedState {
            guard returnedState == state else {
                throw ChatGPTSubscriptionAuthError.stateMismatch
            }
        } else if requireState {
            throw ChatGPTSubscriptionAuthError.stateMismatch
        }
        guard let code = queryItems.first(where: { $0.name == "code" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
            throw ChatGPTSubscriptionAuthError.missingAuthorizationCode
        }
        return code
    }

    func startListening(_ listener: NWListener) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let startState = CallbackStartState(continuation: continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task {
                        await startState.resume(with: .success(()))
                    }
                case let .failed(error):
                    Task {
                        await startState.resume(with: .failure(error))
                    }
                case .cancelled:
                    Task {
                        await startState.resume(with: .failure(ChatGPTSubscriptionAuthError.callbackCancelled))
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await callbackState.waitForCode()
        } onCancel: {
            Task {
                await self.stop()
            }
        }
    }

    func stop() async {
        let state = await callbackState.stop()
        state.listener?.listener.cancel()
        state.continuation?.resume(throwing: ChatGPTSubscriptionAuthError.callbackCancelled)
    }

    func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self] data, _, _, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                self.sendResponse(
                    statusCode: 400,
                    body: Self.errorHTML("Unable to read sign-in callback."),
                    on: connection
                )
                self.complete(.failure(ChatGPTSubscriptionAuthError.callbackRequestInvalid))
                return
            }

            do {
                guard let path = self.callbackPath(from: data),
                      path == "/auth/callback" else {
                    self.sendResponse(
                        statusCode: 404,
                        body: Self.errorHTML("This callback does not belong to ZenCODE."),
                        on: connection
                    )
                    return
                }
                let code = try self.authorizationCode(from: data)
                self.sendResponse(
                    statusCode: 200,
                    body: Self.successHTML(),
                    on: connection
                )
                self.complete(.success(code))
            } catch {
                self.sendResponse(
                    statusCode: 400,
                    body: Self.errorHTML(error.localizedDescription),
                    on: connection
                )
                self.complete(.failure(error))
            }
        }
    }

    func callbackPath(from data: Data?) -> String? {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\n").first else {
            return nil
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            return nil
        }
        return components.path
    }

    func authorizationCode(from data: Data?) throws -> String {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\n").first else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }

        let target = String(parts[1])
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        guard components.path == "/auth/callback" else {
            throw ChatGPTSubscriptionAuthError.callbackRequestInvalid
        }
        return try authorizationCode(from: components, requireState: true)
    }

    func complete(_ result: Result<String, Error>) {
        Task {
            let state = await callbackState.complete(result)
            state.listener?.listener.cancel()
            state.continuation?.resume(with: result)
        }
    }

    func sendResponse(
        statusCode: Int,
        body: String,
        on connection: NWConnection
    ) {
        let reason = statusCode == 200 ? "OK" : "Bad Request"
        let bodyData = Data(body.utf8)
        var response = Data(
            """
            HTTP/1.1 \(statusCode) \(reason)
            Content-Type: text/html; charset=utf-8
            Content-Length: \(bodyData.count)
            Connection: close
            
            """.utf8
        )
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    static func successHTML() -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>ZenCODE</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;">
        <h1>ChatGPT connected</h1>
        <p>You can close this window and return to ZenCODE.</p>
        </body>
        </html>
        """
    }

    static func errorHTML(_ message: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>ZenCODE</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;">
        <h1>Sign-in failed</h1>
        <p>\(message)</p>
        </body>
        </html>
        """
    }
}

private struct ChatGPTSubscriptionCallbackListener: @unchecked Sendable {
    let listener: NWListener
}

private actor ChatGPTSubscriptionCallbackServerState {
    typealias CompletionState = (
        listener: ChatGPTSubscriptionCallbackListener?,
        continuation: CheckedContinuation<String, Error>?
    )

    private var listener: ChatGPTSubscriptionCallbackListener?
    private var waitContinuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var isStopped = false

    func setListener(_ listener: NWListener) {
        self.listener = ChatGPTSubscriptionCallbackListener(listener: listener)
    }

    func clearListener(_ listener: NWListener) {
        guard self.listener?.listener === listener else {
            return
        }
        self.listener = nil
    }

    func waitForCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingResult {
                self.pendingResult = nil
                continuation.resume(with: pendingResult)
                return
            }
            if isStopped {
                continuation.resume(throwing: ChatGPTSubscriptionAuthError.callbackCancelled)
                return
            }
            waitContinuation = continuation
        }
    }

    func stop() -> CompletionState {
        guard !isStopped else {
            return (nil, nil)
        }
        isStopped = true
        let state = (listener: listener, continuation: waitContinuation)
        listener = nil
        waitContinuation = nil
        return state
    }

    func complete(_ result: Result<String, Error>) -> CompletionState {
        guard !isStopped else {
            return (nil, nil)
        }
        isStopped = true
        let state = (listener: listener, continuation: waitContinuation)
        listener = nil
        waitContinuation = nil
        if state.continuation == nil {
            pendingResult = result
        }
        return state
    }
}

private actor CallbackStartState {
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Void, Error>) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
#endif
