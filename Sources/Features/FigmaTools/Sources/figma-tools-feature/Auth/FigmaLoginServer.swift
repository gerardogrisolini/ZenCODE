//
//  FigmaLoginServer.swift
//  ZenCODE
//
//  Loopback HTTP server of the Figma sign-in page. It only binds 127.0.0.1;
//  every POST must carry the one-time form token embedded in the page it
//  served and come from a loopback origin, so another website open in the
//  same browser (or a DNS-rebinding page) cannot plant a foreign login.
//
//  Everything that decides what the server answers (request limit, Host and
//  Origin checks, form token, single verification at a time, result and
//  timeout) is platform-neutral and lives here, shared by every transport.
//  A transport only owns the sockets: `FigmaLoginNetworkTransport` (Network
//  framework, macOS) and `FigmaLoginNIOTransport` (SwiftNIO, Linux).
//

import Foundation
import Synchronization
import ToolCore

struct FigmaLoginValidationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

/// Request parsing and origin checks of the sign-in server (platform-neutral).
enum FigmaLoginHTTP {
    /// Upper bound of one request (headers plus form body) read from a connection.
    static let maximumRequestSize = 64 * 1024

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
        let isComplete: Bool
    }

    /// What the server writes back before closing the connection.
    struct Response: Sendable, Equatable {
        let statusCode: Int
        let html: String

        static let notFound = Response(statusCode: 404, html: FigmaLoginPage.notFound)
        static let forbidden = Response(statusCode: 403, html: FigmaLoginPage.notFound)
        static let requestTooLarge = Response(statusCode: 413, html: FigmaLoginPage.notFound)

        /// The complete HTTP/1.1 message: status line, headers, and body.
        func serialized() -> Data {
            let body = Data(html.utf8)
            let header = [
                "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(statusCode))",
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
            return payload
        }

        private static func reasonPhrase(_ statusCode: Int) -> String {
            switch statusCode {
            case 200: return "OK"
            case 403: return "Forbidden"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 409: return "Conflict"
            case 413: return "Content Too Large"
            default: return "Status \(statusCode)"
            }
        }
    }

    /// Accumulates the bytes of one connection until they form a complete
    /// request, enforcing the request size limit before anything is parsed.
    struct RequestReader {
        enum Outcome {
            case incomplete
            case request(Request)
            case tooLarge
        }

        private var buffer = Data()
        private let limit: Int

        init(limit: Int = FigmaLoginHTTP.maximumRequestSize) {
            self.limit = limit
        }

        mutating func append(_ data: Data) -> Outcome {
            buffer.append(data)
            if buffer.count > limit { return .tooLarge }
            if let request = FigmaLoginHTTP.parse(buffer), request.isComplete {
                return .request(request)
            }
            return .incomplete
        }
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

/// Routing and security rules of the sign-in page, independent of how the
/// bytes reach it: both transports hand every complete request to `handle`.
final class FigmaLoginFlow: Sendable {
    typealias Validator = @Sendable (String) async -> Result<FigmaStoredCredential, FigmaLoginValidationError>

    let formToken: String
    let state = FigmaLoginState()
    private let reason: FigmaLoginReason
    private let validate: Validator

    init(reason: FigmaLoginReason, validate: @escaping Validator) {
        self.reason = reason
        self.validate = validate
        self.formToken = FigmaLoginHTTP.makeFormToken()
    }

    /// Answers one complete request. `respond` is called at most once, from
    /// any thread, and only when the connection should still be answered.
    func handle(
        _ request: FigmaLoginHTTP.Request,
        respond: @escaping @Sendable (FigmaLoginHTTP.Response) -> Void
    ) {
        guard request.path == "/" else {
            respond(.notFound)
            return
        }
        guard FigmaLoginHTTP.isLoopbackHost(request.headers["host"]) else {
            respond(.forbidden)
            return
        }

        switch request.method {
        case "GET":
            respond(formResponse(error: nil, statusCode: 200))
        case "POST":
            let fields = FigmaLoginHTTP.parseFormURLEncoded(request.body)
            guard FigmaLoginHTTP.isLoopbackOrigin(request.headers["origin"]),
                  FigmaLoginHTTP.constantTimeEquals(fields["state"] ?? "", formToken) else {
                respond(formResponse(
                    error: "The submission did not come from this sign-in page. Reload the page and try again.",
                    statusCode: 403
                ))
                return
            }
            guard state.beginSubmission() else {
                respond(formResponse(error: "A sign-in is already being verified. Please wait.", statusCode: 409))
                return
            }
            let token = fields["token"] ?? ""
            let validate = self.validate
            let task = Task(name: "FigmaLogin.validate") { [weak self] in
                guard let self else { return }
                let result = await validate(token)
                guard let completion = self.state.finishSubmission(with: result) else { return }
                // Answer the browser before the waiter is released: the waiter
                // stops the transport, which must not cut this response short.
                switch result {
                case let .success(credential):
                    respond(.init(statusCode: 200, html: FigmaLoginPage.success(accountLabel: credential.accountLabel)))
                case let .failure(error):
                    respond(self.formResponse(error: error.localizedDescription, statusCode: 200))
                }
                completion.deliver()
            }
            state.setSubmissionTask(task)
        default:
            respond(formResponse(error: nil, statusCode: 405))
        }
    }

    private func formResponse(error: String?, statusCode: Int) -> FigmaLoginHTTP.Response {
        FigmaLoginHTTP.Response(
            statusCode: statusCode,
            html: FigmaLoginPage.form(reason: reason, error: error, formToken: formToken)
        )
    }
}

/// Socket layer of the sign-in server. A transport binds `127.0.0.1` on an
/// ephemeral port, reads one request per connection (at most
/// `FigmaLoginHTTP.maximumRequestSize` bytes, via `RequestReader`), passes it
/// to the flow, writes the response, and closes the connection.
protocol FigmaLoginTransport: Sendable {
    /// Starts accepting loopback connections and returns the bound port.
    func start(flow: FigmaLoginFlow) async throws -> UInt16
    /// Stops accepting connections. Safe to call more than once.
    func stop()
}

final class FigmaLoginServer: Sendable {
    typealias Validator = FigmaLoginFlow.Validator

    static let maximumRequestSize = FigmaLoginHTTP.maximumRequestSize

    /// Internal so tests can drive requests without a socket.
    let flow: FigmaLoginFlow
    private let transport: any FigmaLoginTransport

    var formToken: String { flow.formToken }

    /// `transport` defaults to the platform's own: Network on macOS, SwiftNIO elsewhere.
    init(
        reason: FigmaLoginReason,
        transport: (any FigmaLoginTransport)? = nil,
        validate: @escaping Validator
    ) throws {
        self.flow = FigmaLoginFlow(reason: reason, validate: validate)
        self.transport = try transport ?? Self.makePlatformTransport()
    }

    private static func makePlatformTransport() throws -> any FigmaLoginTransport {
        #if os(macOS)
        return try FigmaLoginNetworkTransport()
        #else
        return FigmaLoginNIOTransport()
        #endif
    }

    /// Starts the listener and returns the bound loopback port once ready.
    func start() async throws -> UInt16 {
        try await transport.start(flow: flow)
    }

    func stop() {
        flow.state.stop()
        transport.stop()
    }

    /// Waits for the first token Figma accepted, or fails after `timeout`.
    func waitForResult(timeout: TimeInterval) async throws -> FigmaStoredCredential {
        let state = flow.state
        return try await withThrowingTaskGroup(of: FigmaStoredCredential.self) { group in
            group.addTask(name: "FigmaLogin.waitForResult") {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if let buffered = state.takeResult(orRegister: continuation) {
                            continuation.resume(with: buffered)
                        }
                    }
                } onCancel: {
                    self.stop()
                }
            }
            group.addTask(name: "FigmaLogin.waitForResult-timeout") {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 1) * 1_000_000_000))
                // Resolve the wait as timed out first: stopping resolves it as
                // cancelled, and that must not win the race with this error.
                state.resumeResult(with: .failure(FigmaToolsError.loginTimedOut))
                self.stop()
                throw FigmaToolsError.loginTimedOut
            }
            guard let result = try await group.next() else { throw FigmaToolsError.loginTimedOut }
            group.cancelAll()
            return result
        }
    }
}

/// Continuation storage shared by the transport and the awaiting task.
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

    /// Outcome of a verification that still counts: the browser gets an
    /// answer, and `deliver` then releases the waiter when the login was accepted.
    struct Completion: Sendable {
        fileprivate let continuation: CheckedContinuation<FigmaStoredCredential, Error>?
        fileprivate let credential: FigmaStoredCredential?

        func deliver() {
            if let continuation, let credential {
                continuation.resume(returning: credential)
            }
        }
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
    /// attempt. Results arriving after stop or timeout are ignored (`nil`).
    func finishSubmission(with result: Result<FigmaStoredCredential, FigmaLoginValidationError>) -> Completion? {
        state.withLock { state -> Completion? in
            state.isValidatingSubmission = false
            state.submissionTask = nil
            guard !state.isStopped, !state.didResumeResult else { return nil }
            guard case let .success(credential) = result else {
                return Completion(continuation: nil, credential: nil)
            }
            state.didResumeResult = true
            if let continuation = state.resultContinuation {
                state.resultContinuation = nil
                return Completion(continuation: continuation, credential: credential)
            }
            state.pendingResult = .success(credential)
            return Completion(continuation: nil, credential: nil)
        }
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
