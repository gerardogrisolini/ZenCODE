//
//  FigmaLoginServer.swift
//  ZenCODE
//
//  Loopback HTTP server of the Figma sign-in page. It only binds 127.0.0.1;
//  every POST must carry the one-time form token embedded in the page it
//  served and come from a loopback origin, so another website open in the
//  same browser (or a DNS-rebinding page) cannot plant a foreign login.
//

import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

struct FigmaLoginValidationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

/// Request parsing and origin checks of the sign-in server (platform-neutral).
enum FigmaLoginHTTP {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let isComplete: Bool
    }

    static func parse(_ data: Data) -> Request? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator),
              let headerText = String(data: data.subdata(in: data.startIndex ..< headerRange.lowerBound), encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex ..< colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let body = data.subdata(in: headerRange.upperBound ..< data.endIndex)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        return Request(
            method: method,
            path: path,
            headers: headers,
            body: body,
            isComplete: method == "POST" ? body.count >= contentLength : true
        )
    }

    static func parseFormURLEncoded(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = components.first else { continue }
            result[formDecode(String(rawKey))] = components.count > 1 ? formDecode(String(components[1])) : ""
        }
        return result
    }

    private static func formDecode(_ value: String) -> String {
        let spaced = value.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }

    static func makeFormToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0 ..< 32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Compares two tokens without short-circuiting on the first mismatch.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// Accepts `127.0.0.1`, `localhost` and `[::1]` with or without a port; a
    /// missing header (HTTP/1.0 clients) is tolerated.
    static func isLoopbackHost(_ hostHeader: String?) -> Bool {
        guard let hostHeader = hostHeader?.trimmingCharacters(in: .whitespaces).nilIfBlank else { return true }
        return isLoopbackAuthority(hostHeader)
    }

    /// Accepts a missing `Origin` or an explicit loopback `http://` origin; a
    /// cross-site form post always carries its foreign origin.
    static func isLoopbackOrigin(_ originHeader: String?) -> Bool {
        guard let origin = originHeader?.trimmingCharacters(in: .whitespaces).nilIfBlank else { return true }
        guard origin.lowercased() != "null",
              let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host else {
            return false
        }
        return isLoopbackAuthority(host)
    }

    private static func isLoopbackAuthority(_ authority: String) -> Bool {
        let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var value = authority.lowercased()
        if loopbackHosts.contains(value) { return true }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return false }
            value = String(value[value.index(after: value.startIndex) ..< close])
        } else if let colon = value.lastIndex(of: ":"), value[colon...].dropFirst().allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }
        return loopbackHosts.contains(value)
    }
}

#if os(macOS)
import Network

final class FigmaLoginServer: Sendable {
    typealias Validator = @Sendable (String) async -> Result<FigmaStoredCredential, FigmaLoginValidationError>

    static let maximumRequestSize = 64 * 1024
    static let startTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "FigmaTools.FigmaLoginServer")
    private let listener: NWListener
    private let reason: FigmaLoginReason
    private let validate: Validator
    private let state = FigmaLoginState()
    let formToken: String

    init(reason: FigmaLoginReason, validate: @escaping Validator) throws {
        self.reason = reason
        self.validate = validate
        self.formToken = FigmaLoginHTTP.makeFormToken()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        do {
            self.listener = try NWListener(using: parameters)
        } catch {
            throw FigmaToolsError.loginFailed("unable to start the local sign-in page. \(error.localizedDescription)")
        }
    }

    /// Starts the listener and returns the bound loopback port once ready.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: FigmaToolsError.loginFailed("the sign-in page was stopped."))
                    return
                }
                let state = self.state
                let timeout = Task(name: "FigmaLogin.start-timeout") {
                    try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    state.resumeReadiness(with: .failure(
                        FigmaToolsError.loginFailed("the local sign-in page did not become ready in time.")
                    ))
                }
                state.setReadiness(continuation, timeout: timeout)
                listener.stateUpdateHandler = { [weak self] listenerState in
                    self?.handleListenerState(listenerState)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                listener.start(queue: queue)
            }
        }
        guard let port = listener.port?.rawValue else {
            throw FigmaToolsError.loginFailed("the local sign-in page did not report a port.")
        }
        return port
    }

    func stop() {
        state.stop()
        queue.async {
            self.listener.cancel()
        }
    }

    /// Waits for the first token Figma accepted, or fails after `timeout`.
    func waitForResult(timeout: TimeInterval) async throws -> FigmaStoredCredential {
        try await withThrowingTaskGroup(of: FigmaStoredCredential.self) { group in
            group.addTask(name: "FigmaLogin.waitForResult") {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if let buffered = self.state.takeResult(orRegister: continuation) {
                            continuation.resume(with: buffered)
                        }
                    }
                } onCancel: {
                    self.stop()
                }
            }
            group.addTask(name: "FigmaLogin.waitForResult-timeout") {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                self.stop()
                throw FigmaToolsError.loginTimedOut
            }
            guard let result = try await group.next() else { throw FigmaToolsError.loginTimedOut }
            group.cancelAll()
            return result
        }
    }

    private func handleListenerState(_ listenerState: NWListener.State) {
        switch listenerState {
        case .ready:
            state.resumeReadiness(with: .success(()))
        case let .failed(error):
            let wrapped = FigmaToolsError.loginFailed("the local sign-in page failed. \(error.localizedDescription)")
            state.resumeReadiness(with: .failure(wrapped))
            state.resumeResult(with: .failure(wrapped))
        case .cancelled:
            let stopped = FigmaToolsError.loginFailed("the sign-in page was stopped.")
            state.resumeReadiness(with: .failure(stopped))
            state.resumeResult(with: .failure(stopped))
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            if error != nil {
                connection.cancel()
                return
            }
            if buffer.count > Self.maximumRequestSize {
                self.sendHTML(FigmaLoginPage.notFound, statusCode: 413, on: connection)
                return
            }
            if let request = FigmaLoginHTTP.parse(buffer), request.isComplete {
                self.route(request, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func route(_ request: FigmaLoginHTTP.Request, on connection: NWConnection) {
        guard request.path == "/" else {
            sendHTML(FigmaLoginPage.notFound, statusCode: 404, on: connection)
            return
        }
        guard FigmaLoginHTTP.isLoopbackHost(request.headers["host"]) else {
            sendHTML(FigmaLoginPage.notFound, statusCode: 403, on: connection)
            return
        }

        switch request.method {
        case "GET":
            sendHTML(formPage(error: nil), statusCode: 200, on: connection)
        case "POST":
            let fields = FigmaLoginHTTP.parseFormURLEncoded(request.body)
            guard FigmaLoginHTTP.isLoopbackOrigin(request.headers["origin"]),
                  FigmaLoginHTTP.constantTimeEquals(fields["state"] ?? "", formToken) else {
                sendHTML(
                    formPage(error: "The submission did not come from this sign-in page. Reload the page and try again."),
                    statusCode: 403,
                    on: connection
                )
                return
            }
            guard state.beginSubmission() else {
                sendHTML(
                    formPage(error: "A sign-in is already being verified. Please wait."),
                    statusCode: 409,
                    on: connection
                )
                return
            }
            let token = fields["token"] ?? ""
            let validate = self.validate
            let task = Task(name: "FigmaLogin.validate") { [weak self] in
                guard let self else { return }
                let result = await validate(token)
                guard self.state.finishSubmission(with: result) else { return }
                switch result {
                case let .success(credential):
                    self.sendHTML(FigmaLoginPage.success(accountLabel: credential.accountLabel), statusCode: 200, on: connection)
                case let .failure(error):
                    self.sendHTML(self.formPage(error: error.localizedDescription), statusCode: 200, on: connection)
                }
            }
            state.setSubmissionTask(task)
        default:
            sendHTML(formPage(error: nil), statusCode: 405, on: connection)
        }
    }

    private func formPage(error: String?) -> String {
        FigmaLoginPage.form(reason: reason, error: error, formToken: formToken)
    }

    private func sendHTML(_ html: String, statusCode: Int, on connection: NWConnection) {
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized)",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            // The page embeds the one-time form token: never cache it. With
            // `same-origin` the form POST keeps a loopback Origin header.
            "Cache-Control: no-store",
            "Referrer-Policy: same-origin",
            "X-Content-Type-Options: nosniff",
            "X-Frame-Options: DENY",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Continuation storage shared by the listener queue and the awaiting task.
final class FigmaLoginState: Sendable {
    private struct State: Sendable {
        var readinessContinuation: CheckedContinuation<Void, Error>?
        var readinessTimeout: Task<Void, Never>?
        var resultContinuation: CheckedContinuation<FigmaStoredCredential, Error>?
        var pendingResult: Result<FigmaStoredCredential, Error>?
        var didResumeReadiness = false
        var didResumeResult = false
        var isStopped = false
        var isValidatingSubmission = false
        var submissionTask: Task<Void, Never>?
    }

    private let state = Mutex(State())

    func setReadiness(_ continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>?) {
        state.withLock { state in
            state.readinessContinuation = continuation
            state.readinessTimeout = timeout
        }
    }

    func resumeReadiness(with result: Result<Void, Error>) {
        let resumption: (CheckedContinuation<Void, Error>, Task<Void, Never>?)? = state.withLock { state in
            guard !state.didResumeReadiness, let continuation = state.readinessContinuation else { return nil }
            state.didResumeReadiness = true
            state.readinessContinuation = nil
            let timeout = state.readinessTimeout
            state.readinessTimeout = nil
            return (continuation, timeout)
        }
        if let (continuation, timeout) = resumption {
            timeout?.cancel()
            continuation.resume(with: result)
        }
    }

    func takeResult(
        orRegister continuation: CheckedContinuation<FigmaStoredCredential, Error>
    ) -> Result<FigmaStoredCredential, Error>? {
        state.withLock { state in
            if let pending = state.pendingResult {
                state.pendingResult = nil
                state.didResumeResult = true
                return pending
            }
            state.resultContinuation = continuation
            return nil
        }
    }

    func resumeResult(with result: Result<FigmaStoredCredential, Error>) {
        let continuation: CheckedContinuation<FigmaStoredCredential, Error>? = state.withLock { state in
            guard !state.didResumeResult else { return nil }
            guard let continuation = state.resultContinuation else {
                state.didResumeResult = true
                if state.pendingResult == nil {
                    state.pendingResult = result
                }
                return nil
            }
            state.didResumeResult = true
            state.resultContinuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    /// At most one token verification runs at a time.
    func beginSubmission() -> Bool {
        state.withLock { state in
            guard !state.isStopped, !state.didResumeResult, !state.isValidatingSubmission else { return false }
            state.isValidatingSubmission = true
            return true
        }
    }

    func setSubmissionTask(_ task: Task<Void, Never>) {
        let cancelTask = state.withLock { state -> Bool in
            guard !state.isStopped, state.isValidatingSubmission else { return true }
            state.submissionTask = task
            return false
        }
        if cancelTask {
            task.cancel()
        }
    }

    /// Only an accepted token resolves the flow; a rejected one allows a new
    /// attempt. Results arriving after stop or timeout are ignored.
    func finishSubmission(with result: Result<FigmaStoredCredential, FigmaLoginValidationError>) -> Bool {
        let completion = state.withLock { state -> (CheckedContinuation<FigmaStoredCredential, Error>?, Bool) in
            state.isValidatingSubmission = false
            state.submissionTask = nil
            guard !state.isStopped, !state.didResumeResult else { return (nil, false) }
            guard case let .success(credential) = result else { return (nil, true) }
            state.didResumeResult = true
            if let continuation = state.resultContinuation {
                state.resultContinuation = nil
                return (continuation, true)
            }
            state.pendingResult = .success(credential)
            return (nil, true)
        }
        if case let .success(credential) = result {
            completion.0?.resume(returning: credential)
        }
        return completion.1
    }

    func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isStopped = true
            state.isValidatingSubmission = false
            let task = state.submissionTask
            state.submissionTask = nil
            return task
        }
        task?.cancel()
        resumeResult(with: .failure(CancellationError()))
    }
}
#endif
