//
//  BrowserNetworkGuard.swift
//  BrowserToolsFeature
//
//  Per-invocation request interception for the opt-in Browser feature. This is
//  deliberately not represented as a permanent network sandbox: a one-shot
//  feature process cannot supervise a persistent Chrome target between calls.
//

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
    private let session: CDPSession
    private let requestPolicy: BrowserNetworkRequestPolicy
    private let lock = NSLock()
    private var handlerToken: UUID?
    private var firstViolation: BrowserNetworkGuardViolation?

    init(session: CDPSession, requestPolicy: BrowserNetworkRequestPolicy) {
        self.session = session
        self.requestPolicy = requestPolicy
    }

    func install() async throws {
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
        let token = lock.withLock { () -> UUID? in
            let token = handlerToken
            handlerToken = nil
            return token
        }
        if let token {
            session.removeEventHandler(token)
        }
        _ = try? await session.send(method: "Fetch.disable")
    }

    func validateCurrentDocument() async throws {
        let url = try await session.evalString("location.href || ''")
        try requestPolicy.validateRequestURL(url)
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
        Task { [weak self] in
            await self?.decide(requestID: request.requestID, url: request.url)
        }
    }

    private func decide(requestID: String, url: String) async {
        do {
            try requestPolicy.validateRequestURL(url)
            _ = try await session.send(
                method: "Fetch.continueRequest",
                params: ["requestId": requestID]
            )
        } catch {
            recordViolation(url: url)
            _ = try? await session.send(
                method: "Fetch.failRequest",
                params: [
                    "requestId": requestID,
                    "errorReason": "BlockedByClient",
                ]
            )
        }
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
