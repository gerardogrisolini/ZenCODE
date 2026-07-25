//
//  BrowserNetworkGuard.swift
//  BrowserToolsFeature
//
//  Per-invocation request interception for the opt-in Browser feature. This is
//  deliberately not represented as a permanent network sandbox: a one-shot
//  feature process cannot supervise a persistent Chrome target between calls.
//

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum BrowserNetworkGuardError: LocalizedError {
    case unsupportedRequestScheme(String)
    case unresolvedHost(String)
    case noResolvedAddresses(String)
    case loopbackNotAuthorized(String)
    case unexpectedResolvedLoopback(String)
    case blockedRequest(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedRequestScheme(scheme):
            "Browser blocked a request using unsupported scheme '\(scheme)'."
        case let .unresolvedHost(host):
            "Browser could not safely resolve request host '\(host)', so the request was blocked."
        case let .noResolvedAddresses(host):
            "Browser resolved no numeric addresses for request host '\(host)', so the request was blocked."
        case let .loopbackNotAuthorized(url):
            "Browser blocked an automatic loopback request to '\(url)' because the current page was not opened or explicitly navigated as a local-development page."
        case let .unexpectedResolvedLoopback(url):
            "Browser blocked '\(url)' because its non-loopback host resolved to a loopback address."
        case let .blockedRequest(url):
            "Browser blocked a network request to '\(url)' under its URL and private-network policy."
        }
    }
}

/// A synchronous resolver makes the security decision deterministic and lets
/// unit tests inject fixed DNS answers. It is intentionally used immediately
/// before Fetch.continueRequest; it reduces DNS-rebinding exposure but cannot
/// pin Chrome's eventual transport connection without a proxy/firewall.
protocol BrowserHostResolving: Sendable {
    func resolve(host: String) throws -> [String]
}

struct BrowserSystemHostResolver: BrowserHostResolving {
    func resolve(host: String) throws -> [String] {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty else {
            throw BrowserNetworkGuardError.unresolvedHost(host)
        }
        // RFC 6761 makes these loopback names special in browsers. Resolving
        // them explicitly avoids platform resolver differences while retaining
        // Browser's intended local-development support.
        if normalizedHost.caseInsensitiveCompare("localhost") == .orderedSame
            || normalizedHost.lowercased().hasSuffix(".localhost")
        {
            return ["127.0.0.1", "::1"]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = 0
        hints.ai_protocol = 0
        hints.ai_flags = 0
        var rawResults: UnsafeMutablePointer<addrinfo>?
        let status = normalizedHost.withCString { hostPointer in
            getaddrinfo(hostPointer, nil, &hints, &rawResults)
        }
        guard status == 0, let firstResult = rawResults else {
            throw BrowserNetworkGuardError.unresolvedHost(host)
        }
        defer { freeaddrinfo(firstResult) }

        var addresses = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = firstResult
        while let entry = current {
            let info = entry.pointee
            if let socketAddress = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let nameStatus = getnameinfo(
                    socketAddress,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                if nameStatus == 0 {
                    let nullTerminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
                    let address = String(
                        decoding: buffer[..<nullTerminator].map(UInt8.init(bitPattern:)),
                        as: UTF8.self
                    )
                    addresses.insert(address)
                }
            }
            current = info.ai_next
        }
        let values = addresses.sorted()
        guard !values.isEmpty else {
            throw BrowserNetworkGuardError.noResolvedAddresses(host)
        }
        return values
    }
}

/// Thread-safe single-shot holder for the continuation that bridges a blocking
/// DNS resolver to async Swift code. Exactly one of the resolver result or a
/// cancellation error resumes the continuation, regardless of arrival order, so
/// a blocking resolver can be abandoned on cancellation without a double resume.
private final class BrowserOffloadResolutionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var pending: Result<[String], Error>?

    func attach(_ continuation: CheckedContinuation<[String], Error>) {
        lock.lock()
        if let early = pending {
            pending = nil
            lock.unlock()
            continuation.resume(with: early)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resume(with result: Result<[String], Error>) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }
}

/// Validates URLs that Chrome is about to request, including WebSocket
/// handshakes when Fetch reports them. Direct navigation tools still use
/// BrowserURLPolicy separately and continue to permit only HTTP(S).
struct BrowserNetworkRequestPolicy: Sendable {
    let urlPolicy: BrowserURLPolicy
    let resolver: any BrowserHostResolving
    /// Loopback is useful for a local app's assets, HMR, and WebSocket traffic,
    /// but it is a capability tied to an explicitly local initial/destination
    /// URL rather than a grant inherited by unrelated public pages.
    let allowsLoopback: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolver: any BrowserHostResolving = BrowserSystemHostResolver(),
        allowsLoopback: Bool = false
    ) {
        self.urlPolicy = BrowserURLPolicy(environment: environment)
        self.resolver = resolver
        self.allowsLoopback = allowsLoopback
    }

    init(
        urlPolicy: BrowserURLPolicy,
        resolver: any BrowserHostResolving,
        allowsLoopback: Bool = false
    ) {
        self.urlPolicy = urlPolicy
        self.resolver = resolver
        self.allowsLoopback = allowsLoopback
    }

    func validateRequestURL(_ rawURL: String) throws {
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw BrowserNetworkGuardError.unsupportedRequestScheme("<missing>")
        }

        switch scheme {
        case "about", "blob", "data":
            return
        case "http", "https":
            break
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            throw BrowserNetworkGuardError.unsupportedRequestScheme(scheme)
        }

        guard let navigationURL = components.url else {
            throw BrowserNetworkGuardError.unsupportedRequestScheme(scheme)
        }
        let validatedURL = try urlPolicy.validate(navigationURL.absoluteString)
        guard let host = validatedURL.host, !host.isEmpty else {
            throw BrowserNetworkGuardError.unresolvedHost(components.host ?? "")
        }
        let isExplicitLoopback = urlPolicy.isLoopbackHost(host)
        guard !isExplicitLoopback || allowsLoopback else {
            throw BrowserNetworkGuardError.loopbackNotAuthorized(
                BrowserNetworkURLRedaction.apply(to: rawURL)
            )
        }
        let addresses = try resolver.resolve(host: host)
        for address in addresses {
            guard isExplicitLoopback || !urlPolicy.isLoopbackHost(address) else {
                throw BrowserNetworkGuardError.unexpectedResolvedLoopback(
                    BrowserNetworkURLRedaction.apply(to: rawURL)
                )
            }
            try urlPolicy.validateResolvedAddress(address)
        }
    }

    /// Async counterpart of ``validateRequestURL(_:)`` that applies the same
    /// URL, loopback, and resolved-address policy checks, but resolves the
    /// request host off the cooperative thread pool so a slow or blocking DNS
    /// lookup cannot stall request interception. It is cancellation-aware: when
    /// the surrounding task is cancelled while a resolution is pending, it
    /// throws ``CancellationError`` promptly instead of waiting for the
    /// (possibly blocking) resolver to return. The synchronous policy used by
    /// ``validateRequestURL(_:)`` is unchanged.
    func validateRequestURLOffloaded(_ rawURL: String) async throws {
        try Task.checkCancellation()

        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw BrowserNetworkGuardError.unsupportedRequestScheme("<missing>")
        }

        switch scheme {
        case "about", "blob", "data":
            return
        case "http", "https":
            break
        case "ws":
            components.scheme = "http"
        case "wss":
            components.scheme = "https"
        default:
            throw BrowserNetworkGuardError.unsupportedRequestScheme(scheme)
        }

        guard let navigationURL = components.url else {
            throw BrowserNetworkGuardError.unsupportedRequestScheme(scheme)
        }
        let validatedURL = try urlPolicy.validate(navigationURL.absoluteString)
        guard let host = validatedURL.host, !host.isEmpty else {
            throw BrowserNetworkGuardError.unresolvedHost(components.host ?? "")
        }
        let isExplicitLoopback = urlPolicy.isLoopbackHost(host)
        guard !isExplicitLoopback || allowsLoopback else {
            throw BrowserNetworkGuardError.loopbackNotAuthorized(
                BrowserNetworkURLRedaction.apply(to: rawURL)
            )
        }

        let addresses = try await resolveHostOffloaded(host)

        let redactedURL = BrowserNetworkURLRedaction.apply(to: rawURL)
        for address in addresses {
            guard isExplicitLoopback || !urlPolicy.isLoopbackHost(address) else {
                throw BrowserNetworkGuardError.unexpectedResolvedLoopback(redactedURL)
            }
            try urlPolicy.validateResolvedAddress(address)
        }
    }

    /// Runs the blocking resolver on a global dispatch queue (never on the
    /// cooperative thread pool) and resumes the awaiting continuation either
    /// with the resolver's result or, if the surrounding task is cancelled
    /// first, with ``CancellationError``.
    private func resolveHostOffloaded(_ host: String) async throws -> [String] {
        let box = BrowserOffloadResolutionBox()
        let resolver = self.resolver
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
                box.attach(continuation)
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result<[String], Error> { try resolver.resolve(host: host) }
                    box.resume(with: result)
                }
            }
        } onCancel: {
            box.resume(throwing: CancellationError())
        }
    }
}

private struct BrowserNetworkGuardViolation: Sendable {
    let redactedURL: String
}

struct BrowserFetchPausedRequest: Sendable, Equatable {
    let requestID: String
    let url: String

    static func decode(_ event: CDPEvent) -> Self? {
        guard event.method == "Fetch.requestPaused",
              let requestID = event.params["requestId"] as? String,
              let request = event.params["request"] as? [String: Any],
              let url = request["url"] as? String,
              !requestID.isEmpty,
              !url.isEmpty
        else {
            return nil
        }
        return BrowserFetchPausedRequest(requestID: requestID, url: url)
    }
}

/// Fetch request-stage interception blocks policy-violating redirects,
/// documents, frames, and ordinary subresources before the request is sent for
/// as long as a Browser tool invocation has its CDP session open.
final class BrowserNetworkGuard: @unchecked Sendable {
    private static let maximumConcurrentDecisions = 4

    private let session: CDPSession
    private let requestPolicy: BrowserNetworkRequestPolicy
    private let lock = NSLock()
    private var handlerToken: UUID?
    private var firstViolation: BrowserNetworkGuardViolation?
    private var queuedRequests: [BrowserFetchPausedRequest] = []
    private var decisionTasks: [UUID: Task<Void, Never>] = [:]
    private var isStopped = false

    init(session: CDPSession, requestPolicy: BrowserNetworkRequestPolicy) {
        self.session = session
        self.requestPolicy = requestPolicy
    }

    deinit {
        let (token, tasks) = lock.withLock { () -> (UUID?, [Task<Void, Never>]) in
            isStopped = true
            queuedRequests.removeAll()
            let token = handlerToken
            handlerToken = nil
            let tasks = Array(decisionTasks.values)
            decisionTasks.removeAll()
            return (token, tasks)
        }
        if let token {
            session.removeEventHandler(token)
        }
        tasks.forEach { $0.cancel() }
    }

    func install() async throws {
        lock.withLock {
            isStopped = false
            firstViolation = nil
        }
        let token = session.addEventHandler { [weak self] event in
            self?.consume(event)
        }
        do {
            _ = try await session.send(
                method: "Fetch.enable",
                params: [
                    "patterns": [[
                        "urlPattern": "*",
                        "requestStage": "Request",
                    ]],
                ]
            )
            lock.withLock {
                handlerToken = token
            }
        } catch {
            session.removeEventHandler(token)
            throw error
        }
    }

    func stop() async {
        let (token, tasks) = lock.withLock { () -> (UUID?, [Task<Void, Never>]) in
            isStopped = true
            queuedRequests.removeAll()
            let token = handlerToken
            handlerToken = nil
            let tasks = Array(decisionTasks.values)
            decisionTasks.removeAll()
            return (token, tasks)
        }
        if let token {
            session.removeEventHandler(token)
        }
        tasks.forEach { $0.cancel() }
        _ = try? await session.send(method: "Fetch.disable")
    }

    func validateCurrentDocument() async throws {
        let url = try await session.evalString("location.href || ''")
        try await requestPolicy.validateRequestURLOffloaded(url)
    }

    func throwIfBlocked() throws {
        lock.lock()
        let violation = firstViolation
        lock.unlock()
        if let violation {
            throw BrowserNetworkGuardError.blockedRequest(violation.redactedURL)
        }
    }

    private func consume(_ event: CDPEvent) {
        guard let request = BrowserFetchPausedRequest.decode(event) else { return }
        lock.withLock {
            guard !isStopped else { return }
            queuedRequests.append(request)
            startQueuedDecisionsLocked()
        }
    }

    /// Must be called with `lock` held. The tasks are recorded before the lock
    /// is released, so teardown can always find and cancel every decision.
    private func startQueuedDecisionsLocked() {
        while !isStopped,
              decisionTasks.count < Self.maximumConcurrentDecisions,
              !queuedRequests.isEmpty
        {
            let request = queuedRequests.removeFirst()
            let identifier = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.decide(requestID: request.requestID, url: request.url)
                self.finishDecision(identifier)
            }
            decisionTasks[identifier] = task
        }
    }

    private func finishDecision(_ identifier: UUID) {
        lock.withLock {
            decisionTasks.removeValue(forKey: identifier)
            startQueuedDecisionsLocked()
        }
    }

    private func decide(requestID: String, url: String) async {
        do {
            try await requestPolicy.validateRequestURLOffloaded(url)
            try Task.checkCancellation()
            guard acceptsDecisions else { return }
            _ = try await session.send(
                method: "Fetch.continueRequest",
                params: ["requestId": requestID]
            )
        } catch is CancellationError {
            // `stop()` owns cancellation. Do not record a policy violation or
            // issue a new CDP command while that teardown is in progress.
            return
        } catch {
            guard acceptsDecisions else { return }
            recordViolation(url: url)
            guard acceptsDecisions else { return }
            _ = try? await session.send(
                method: "Fetch.failRequest",
                params: [
                    "requestId": requestID,
                    "errorReason": "BlockedByClient",
                ]
            )
        }
    }

    private var acceptsDecisions: Bool {
        lock.withLock { !isStopped }
    }

    private func recordViolation(url: String) {
        let redactedURL = BrowserNetworkURLRedaction.apply(to: url)
        lock.lock()
        if firstViolation == nil {
            firstViolation = BrowserNetworkGuardViolation(redactedURL: redactedURL)
        }
        lock.unlock()
    }
}
