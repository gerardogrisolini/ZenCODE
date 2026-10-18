//
//  ChatGPTSubscriptionCallbackServer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if os(macOS)
import Network
#endif
#if canImport(os)
import os
#endif

#if os(macOS)
final class ChatGPTSubscriptionCallbackServer: Sendable {
    /// Port registered with the OAuth client for
    /// `http://localhost:1455/auth/callback`.
    static let defaultPort: UInt16 = 1455

    let state: String
    /// Requested port. `0` asks the IPv4 listener for an ephemeral port, which
    /// the IPv6 listener then reuses (deterministic loopback tests only).
    let port: UInt16
    let queue = DispatchQueue(label: "ZenCODE.ChatGPTSubscriptionCallback")
    private let callbackState = ChatGPTSubscriptionCallbackServerState()

    init(state: String, port: UInt16 = ChatGPTSubscriptionCallbackServer.defaultPort) {
        self.state = state
        self.port = port
    }

    /// Starts loopback-only listeners for the redirect URI host `localhost`.
    ///
    /// Browsers can resolve `localhost` to either `127.0.0.1` or `::1`, so one
    /// listener is bound to each loopback address on the same port; the first
    /// valid callback wins. Nothing listens on LAN interfaces, so a remote host
    /// can neither deliver a code nor tear the sign-in down. The IPv4 listener
    /// is required; the IPv6 one is best effort (hosts with IPv6 disabled),
    /// and browsers fall back to `127.0.0.1` when `::1` refuses connections.
    @discardableResult
    func start() async throws -> ChatGPTSubscriptionCallbackServer {
        let ipv4Listener = try await startLoopbackListener(host: .ipv4(.loopback), port: port)
        guard let boundPort = ipv4Listener.port?.rawValue, boundPort != 0 else {
            await stop()
            throw ChatGPTSubscriptionAuthError.callbackServerUnavailable
        }
        _ = try? await startLoopbackListener(host: .ipv6(.loopback), port: boundPort)
        return self
    }

    /// Port actually bound by the running listeners, if any.
    func boundPort() async -> UInt16? {
        await callbackState.activeListeners().first?.port?.rawValue
    }

    /// Local endpoints the running listeners are restricted to.
    func boundLocalEndpoints() async -> [NWEndpoint] {
        await callbackState.activeListeners().compactMap {
            $0.parameters.requiredLocalEndpoint
        }
    }

    static func loopbackParameters(
        host: NWEndpoint.Host,
        port: UInt16
    ) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: host,
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        // Defense in depth: refuse any non-local peer even if the binding is
        // ever widened.
        parameters.acceptLocalOnly = true
        // Network.framework otherwise reports EADDRINUSE when the IPv6
        // loopback listener binds the port already held by the IPv4 loopback
        // listener; the two specific addresses never overlap.
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func startLoopbackListener(
        host: NWEndpoint.Host,
        port: UInt16
    ) async throws -> NWListener {
        let listener: NWListener
        do {
            listener = try NWListener(
                using: Self.loopbackParameters(host: host, port: port)
            )
        } catch {
            // Surface the failure instead of returning a listener-less server
            // whose waitForCode() would suspend forever.
            throw ChatGPTSubscriptionAuthError.callbackServerUnavailable
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        guard await callbackState.addListener(listener) else {
            // Already completed or stopped.
            throw ChatGPTSubscriptionAuthError.callbackCancelled
        }

        do {
            try await startListening(listener, timeout: .seconds(2))
        } catch {
            listener.cancel()
            await callbackState.removeListener(listener)
            throw ChatGPTSubscriptionAuthError.callbackServerUnavailable
        }
        return listener
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
            return try authorizationCode(from: components, requireState: true)
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
                return try authorizationCode(from: components, requireState: true)
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

    func startListening(_ listener: NWListener, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let startState = CallbackStartState(continuation: continuation)
            // A taken port does not fail the listener: Network.framework keeps
            // it in the waiting state while it retries the bind. Bound the wait
            // so sign-in degrades to the manual code path instead of hanging.
            let timeoutTask = Task(name: "ChatGPT callback start timeout") {
                try? await Task.sleep(for: timeout)
                // Only tear the listener down when this timeout actually won
                // the race; a listener that became ready in the same instant
                // must keep serving.
                let didResume = await startState.resume(with: .failure(ChatGPTSubscriptionAuthError.callbackServerUnavailable))
                if didResume {
                    listener.cancel()
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Task(name: "ChatGPT callback background task") {
                        await startState.resume(with: .success(()))
                        timeoutTask.cancel()
                    }
                case let .failed(error):
                    Task(name: "ChatGPT callback background task") {
                        await startState.resume(with: .failure(error))
                        timeoutTask.cancel()
                    }
                case .cancelled:
                    Task(name: "ChatGPT callback background task") {
                        await startState.resume(with: .failure(ChatGPTSubscriptionAuthError.callbackCancelled))
                        timeoutTask.cancel()
                    }
                case .setup, .waiting:
                    break
                @unknown default:
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
            Task(name: "ChatGPT callback background task") {
                await self.stop()
            }
        }
    }

    func stop() async {
        let state = await callbackState.stop()
        for listener in state.listeners {
            listener.cancel()
        }
        state.continuation?.resume(throwing: ChatGPTSubscriptionAuthError.callbackCancelled)
    }

    /// Outcome of one HTTP request received by the callback listener.
    enum CallbackRequestDecision: Equatable, Sendable {
        /// Valid callback with the expected `state`: finish with the code.
        case authorized(code: String)
        /// Callback carrying the expected `state` but no code (for example an
        /// OAuth error redirect). It is authentic, so it ends the flow.
        case authenticFailure(message: String)
        /// Request for another path: answer 404 and keep waiting.
        case notFound
        /// Malformed request, wrong or missing `state`: answer 400 and keep
        /// waiting, so a spurious request cannot terminate the sign-in.
        case invalid(message: String)

        var statusCode: Int {
            switch self {
            case .authorized: 200
            case .notFound: 404
            case .authenticFailure, .invalid: 400
            }
        }
    }

    /// Pure decision for one received request. Only a request carrying the
    /// expected OAuth `state` can complete the flow.
    func callbackDecision(for data: Data?) -> CallbackRequestDecision {
        guard let data,
              let request = String(data: data, encoding: .utf8),
              let firstLine = request.components(separatedBy: "\n").first else {
            return .invalid(message: ChatGPTSubscriptionAuthError.callbackRequestInvalid.localizedDescription)
        }
        let parts = firstLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2)
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost\(parts[1])") else {
            return .invalid(message: ChatGPTSubscriptionAuthError.callbackRequestInvalid.localizedDescription)
        }
        guard components.path == "/auth/callback" else {
            return .notFound
        }
        let queryItems = components.queryItems ?? []
        guard queryItems.first(where: { $0.name == "state" })?.value == state else {
            return .invalid(message: ChatGPTSubscriptionAuthError.stateMismatch.localizedDescription)
        }
        do {
            return .authorized(code: try authorizationCode(from: components, requireState: true))
        } catch {
            return .authenticFailure(message: error.localizedDescription)
        }
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
                // A broken connection is not a callback; keep waiting.
                self.sendResponse(
                    statusCode: 400,
                    body: Self.errorHTML("Unable to read sign-in callback."),
                    on: connection
                )
                return
            }

            let decision = self.callbackDecision(for: data)
            switch decision {
            case let .authorized(code):
                self.sendResponse(
                    statusCode: decision.statusCode,
                    body: Self.successHTML(),
                    on: connection
                )
                self.complete(.success(code))
            case let .authenticFailure(message):
                self.sendResponse(
                    statusCode: decision.statusCode,
                    body: Self.errorHTML(message),
                    on: connection
                )
                self.complete(.failure(ChatGPTSubscriptionAuthError.missingAuthorizationCode))
            case .notFound:
                self.sendResponse(
                    statusCode: decision.statusCode,
                    body: Self.errorHTML("This callback does not belong to ZenCODE."),
                    on: connection
                )
            case let .invalid(message):
                self.sendResponse(
                    statusCode: decision.statusCode,
                    body: Self.errorHTML(message),
                    on: connection
                )
            }
        }
    }

    func complete(_ result: Result<String, Error>) {
        Task(name: "ChatGPT callback background task") {
            let state = await callbackState.complete(result)
            for listener in state.listeners {
                listener.cancel()
            }
            state.continuation?.resume(with: result)
        }
    }

    func sendResponse(
        statusCode: Int,
        body: String,
        on connection: NWConnection
    ) {
        let reason = switch statusCode {
        case 200: "OK"
        case 404: "Not Found"
        default: "Bad Request"
        }
        let bodyData = Data(body.utf8)
        // HTTP/1.1 requires CRLF line endings; strict clients reject bare LF.
        var response = Data(
            [
                "HTTP/1.1 \(statusCode) \(reason)",
                "Content-Type: text/html; charset=utf-8",
                "Content-Length: \(bodyData.count)",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n").utf8
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
        let escaped = Self.escapeHTML(message)
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>ZenCODE</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,sans-serif;padding:40px;">
        <h1>Sign-in failed</h1>
        <p>\(escaped)</p>
        </body>
        </html>
        """
    }

    static func escapeHTML(_ string: String) -> String {
        var escaped = string
        let replacements: [(String, String)] = [
            ("&", "&amp;"),
            ("<", "&lt;"),
            (">", "&gt;"),
            ("\"", "&quot;"),
            ("'", "&#39;"),
        ]
        // Replace ampersands first to avoid double-escaping the entities
        // introduced by later substitutions.
        for (character, entity) in replacements {
            escaped = escaped.replacingOccurrences(of: character, with: entity)
        }
        return escaped
    }
}

private actor ChatGPTSubscriptionCallbackServerState {
    typealias CompletionState = (
        listeners: [NWListener],
        continuation: CheckedContinuation<String, Error>?
    )

    private var listeners: [NWListener] = []
    private var waitContinuation: CheckedContinuation<String, Error>?
    private var pendingResult: Result<String, Error>?
    private var isStopped = false

    /// Registers a listener; returns false once the flow is already over, in
    /// which case the caller must not start it.
    func addListener(_ listener: NWListener) -> Bool {
        guard !isStopped else {
            return false
        }
        listeners.append(listener)
        return true
    }

    func removeListener(_ listener: NWListener) {
        listeners.removeAll { $0 === listener }
    }

    func activeListeners() -> [NWListener] {
        listeners
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
            if waitContinuation != nil {
                // A concurrent wait is already registered. Never overwrite the
                // existing continuation: resume this waiter immediately so the
                // first waiter is still delivered exactly once.
                continuation.resume(throwing: CancellationError())
                return
            }
            waitContinuation = continuation
        }
    }

    func stop() -> CompletionState {
        guard !isStopped else {
            return ([], nil)
        }
        isStopped = true
        let state = (listeners: listeners, continuation: waitContinuation)
        listeners = []
        waitContinuation = nil
        return state
    }

    func complete(_ result: Result<String, Error>) -> CompletionState {
        guard !isStopped else {
            return ([], nil)
        }
        isStopped = true
        let state = (listeners: listeners, continuation: waitContinuation)
        listeners = []
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

    /// Resumes the continuation exactly once. Returns true when this call
    /// performed the resume, false when a previous resume already happened.
    @discardableResult
    func resume(with result: Result<Void, Error>) -> Bool {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
        return continuation != nil
    }
}
#endif
