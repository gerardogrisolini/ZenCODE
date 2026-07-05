//
//  MCPBrowserOAuthCallbackServer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
#if os(macOS)
import Network
import Synchronization

public nonisolated final class MCPBrowserOAuthCallbackServer: Sendable {
    public let redirectURL: URL
    public let serviceName: String
    public let queue = DispatchQueue(label: "FeatureMCPBridgeKit.MCPBrowserOAuthCallbackServer")
    public let listener: NWListener

    private struct State {
        var readinessContinuation: CheckedContinuation<Void, Error>?
        var callbackContinuation: CheckedContinuation<MCPOAuthCallback, Error>?
        /// Buffers a callback result that arrives before `waitForCallback`
        /// registers its continuation, so early browser callbacks are not lost.
        var pendingCallbackResult: Result<MCPOAuthCallback, Error>?
        var didResumeReadiness = false
        var didResumeCallback = false
    }

    private let state = Mutex(State())

    public init(redirectURL: URL, serviceName: String) throws {
        guard redirectURL.scheme == "http",
              let host = redirectURL.host,
              host == "127.0.0.1" || host == "localhost",
              let port = redirectURL.port,
              let listenerPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw MCPClientError.browserAuthenticationFailed(
                "The \(serviceName) browser sign-in callback URL is invalid."
            )
        }

        self.redirectURL = redirectURL
        self.serviceName = serviceName
        self.listener = try NWListener(using: .tcp, on: listenerPort)
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.state.withLock { state in
                    state.readinessContinuation = continuation
                }
                self.listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                self.listener.start(queue: self.queue)
            }
        }
    }

    public func stop() {
        queue.async {
            self.listener.cancel()
            self.resumeReadinessIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(self.serviceName) browser sign-in was interrupted."
                    )
                )
            )
        }
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> MCPOAuthCallback {
        try await withThrowingTaskGroup(of: MCPOAuthCallback.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        let bufferedResult = self.state.withLock { state -> Result<MCPOAuthCallback, Error>? in
                            if let pending = state.pendingCallbackResult {
                                state.pendingCallbackResult = nil
                                state.didResumeCallback = true
                                return pending
                            }
                            state.callbackContinuation = continuation
                            return nil
                        }
                        if let bufferedResult {
                            continuation.resume(with: bufferedResult)
                        }
                    }
                } onCancel: {
                    self.resumeCallbackIfNeeded(
                        with: .failure(
                            MCPClientError.browserAuthenticationFailed(
                                "The \(self.serviceName) browser sign-in was interrupted."
                            )
                        )
                    )
                }
            }

            group.addTask {
                let timeoutNanoseconds = UInt64(max(timeout, 1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw MCPClientError.browserAuthenticationFailed(
                    "Timed out waiting for \(self.serviceName) sign-in in the browser."
                )
            }

            guard let callback = try await group.next() else {
                throw MCPClientError.invalidResponse
            }

            group.cancelAll()
            return callback
        }
    }

    public func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            resumeReadinessIfNeeded(with: .success(()))
        case let .failed(error):
            let wrappedError = MCPClientError.browserAuthenticationFailed(
                "The MCP client could not start the local \(serviceName) sign-in callback server. \(error.localizedDescription)"
            )
            resumeReadinessIfNeeded(with: .failure(wrappedError))
            resumeCallbackIfNeeded(with: .failure(wrappedError))
        case .cancelled:
            let cancellationError = MCPClientError.browserAuthenticationFailed(
                "The \(serviceName) browser sign-in was interrupted."
            )
            resumeReadinessIfNeeded(with: .failure(cancellationError))
            resumeCallbackIfNeeded(with: .failure(cancellationError))
        default:
            break
        }
    }

    public func handle(connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            self?.handleReceivedRequest(data: data, error: error, connection: connection)
        }
    }

    public func handleReceivedRequest(
        data: Data?,
        error: NWError?,
        connection: NWConnection
    ) {
        if let error {
            sendResponse(
                statusCode: 500,
                title: "\(serviceName) Sign-In Failed",
                message: error.localizedDescription,
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(serviceName) browser sign-in callback failed. \(error.localizedDescription)"
                    )
                )
            )
            return
        }

        guard let data,
              let requestText = String(data: data, encoding: .utf8),
              let firstLine = requestText.components(separatedBy: .newlines).first else {
            sendResponse(
                statusCode: 400,
                title: "Invalid Callback",
                message: "The MCP client received an invalid \(serviceName) sign-in callback.",
                on: connection
            )
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(
                statusCode: 400,
                title: "Invalid Callback",
                message: "The MCP client received an invalid \(serviceName) sign-in callback.",
                on: connection
            )
            return
        }

        let requestTarget = String(parts[1])
        guard let callbackURL = URL(string: "http://\(redirectURL.host ?? "127.0.0.1")\(requestTarget)"),
              callbackURL.path == redirectURL.path,
              let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            sendResponse(
                statusCode: 404,
                title: "Unknown Callback",
                message: "This browser callback does not belong to the MCP client.",
                on: connection
            )
            return
        }

        let queryItems = Dictionary(
            components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
            uniquingKeysWith: { current, _ in current }
        )

        if let oauthError = queryItems["error"], !oauthError.isEmpty {
            let description = queryItems["error_description"] ?? oauthError
            sendResponse(
                statusCode: 400,
                title: "\(serviceName) Sign-In Failed",
                message: description,
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "\(serviceName) sign-in was not completed. \(description)"
                    )
                )
            )
            return
        }

        guard let code = queryItems["code"], !code.isEmpty,
              let state = queryItems["state"], !state.isEmpty else {
            sendResponse(
                statusCode: 400,
                title: "\(serviceName) Sign-In Failed",
                message: "The \(serviceName) sign-in callback did not include the expected authorization code.",
                on: connection
            )
            resumeCallbackIfNeeded(
                with: .failure(
                    MCPClientError.browserAuthenticationFailed(
                        "The \(serviceName) sign-in callback did not include the expected authorization code."
                    )
                )
            )
            return
        }

        sendResponse(
            statusCode: 200,
            title: "\(serviceName) Connected",
            message: "The MCP client has completed \(serviceName) sign-in. You can close this browser tab and return to the app.",
            on: connection
        )
        resumeCallbackIfNeeded(with: .success(MCPOAuthCallback(code: code, state: state)))
    }

    public func sendResponse(
        statusCode: Int,
        title: String,
        message: String,
        on connection: NWConnection
    ) {
        let responseBody = """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        </head>
        <body style="font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 32px;">
        <h1>\(title)</h1>
        <p>\(message)</p>
        </body>
        </html>
        """
        let payload = """
        HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))
        Content-Type: text/html; charset=utf-8
        Content-Length: \(responseBody.utf8.count)
        Connection: close

        \(responseBody)
        """

        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    public func resumeReadinessIfNeeded(with result: Result<Void, Error>) {
        let continuation = state.withLock { state in
            guard !state.didResumeReadiness, let continuation = state.readinessContinuation else {
                return nil as CheckedContinuation<Void, Error>?
            }

            state.didResumeReadiness = true
            state.readinessContinuation = nil
            return continuation
        }

        guard let continuation else {
            return
        }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    public func resumeCallbackIfNeeded(with result: Result<MCPOAuthCallback, Error>) {
        let continuation = state.withLock { state -> CheckedContinuation<MCPOAuthCallback, Error>? in
            guard !state.didResumeCallback else {
                return nil
            }
            guard let continuation = state.callbackContinuation else {
                // No waiter yet: buffer the first result so it is delivered
                // as soon as `waitForCallback` registers its continuation.
                if state.pendingCallbackResult == nil {
                    state.pendingCallbackResult = result
                }
                return nil
            }

            state.didResumeCallback = true
            state.callbackContinuation = nil
            return continuation
        }

        guard let continuation else {
            return
        }
        switch result {
        case let .success(callback):
            continuation.resume(returning: callback)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    public static func reasonPhrase(for statusCode: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }
}
#endif
