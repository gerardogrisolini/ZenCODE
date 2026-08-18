//
//  WebNetworkGuard.swift
//  WebToolsFeature
//
//  Public-network request policy for the Web feature's fetch path. It mirrors
//  the approach of BrowserNetworkRequestPolicy in BrowserTools: every URL the
//  feature is about to request — the initial fetch and each redirect hop — is
//  validated against URL restrictions and then against the addresses its host
//  actually resolves to, so neither a redirect nor DNS rebinding can pivot a
//  public request into loopback, private, or metadata networks.
//

import Dispatch
import Foundation
import Synchronization

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Errors

enum WebURLPolicyError: LocalizedError, Equatable, Sendable {
    case emptyURL
    case invalidURL(String)
    case unsupportedScheme(String)
    case missingHost(String)
    case credentialsNotAllowed(String)
    case restrictedHost(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            "A non-empty http or https URL is required."
        case let .invalidURL(value):
            "Invalid URL: \(value)"
        case let .unsupportedScheme(value):
            "Unsupported URL scheme '\(value)'. Only http and https are supported."
        case let .missingHost(value):
            "URL must include a host: \(value)"
        case .credentialsNotAllowed:
            "URLs containing embedded credentials are not allowed."
        case let .restrictedHost(host):
            "Web access to the restricted host '\(host)' is disabled. Set ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK=1 only when access to a trusted private network is required."
        }
    }
}

enum WebNetworkGuardError: LocalizedError {
    case unsupportedRequestScheme(String)
    case unresolvedHost(String)
    case noResolvedAddresses(String)
    case unexpectedResolvedLoopback(String)
    case blockedRequest(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedRequestScheme(scheme):
            "Web tools blocked a request using unsupported scheme '\(scheme)'."
        case let .unresolvedHost(host):
            "Web tools could not safely resolve request host '\(host)', so the request was blocked."
        case let .noResolvedAddresses(host):
            "Web tools resolved no numeric addresses for request host '\(host)', so the request was blocked."
        case let .unexpectedResolvedLoopback(url):
            "Web tools blocked '\(url)' because its non-loopback host resolved to a loopback address."
        case let .blockedRequest(url):
            "Web tools blocked a network request to '\(url)' under its URL and private-network policy."
        }
    }
}

// MARK: - DNS resolution

/// A synchronous resolver makes the security decision deterministic and lets
/// unit tests inject fixed DNS answers. It mirrors BrowserHostResolving in
/// BrowserTools and is applied immediately before a request continues; it
/// reduces DNS-rebinding exposure but cannot pin the eventual transport
/// connection without a proxy/firewall.
protocol WebHostResolving: Sendable {
    func resolve(host: String) throws -> [String]
}

struct WebSystemHostResolver: WebHostResolving {
    func resolve(host: String) throws -> [String] {
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalizedHost.isEmpty else {
            throw WebNetworkGuardError.unresolvedHost(host)
        }
        // RFC 6761 makes these loopback names special. Resolving them
        // explicitly avoids platform resolver differences.
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
            throw WebNetworkGuardError.unresolvedHost(host)
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
            throw WebNetworkGuardError.noResolvedAddresses(host)
        }
        return values
    }
}

/// Thread-safe single-shot holder that bridges a blocking DNS resolver to
/// async Swift code, mirroring BrowserOffloadResolutionBox. Exactly one of the
/// resolver result or a cancellation error resumes the continuation.
private final class WebOffloadResolutionBox: Sendable {
    private struct State: Sendable {
        var continuation: CheckedContinuation<[String], Error>?
        var pending: Result<[String], Error>?
    }
    private let state = Mutex(State())

    func attach(_ continuation: CheckedContinuation<[String], Error>) {
        let early: Result<[String], Error>? = state.withLock { state in
            if let pending = state.pending {
                state.pending = nil
                return pending
            }
            state.continuation = continuation
            return nil
        }
        if let early {
            continuation.resume(with: early)
        }
    }

    func resume(with result: Result<[String], Error>) {
        let continuation: CheckedContinuation<[String], Error>? = state.withLock { state in
            if let continuation = state.continuation {
                state.continuation = nil
                return continuation
            }
            state.pending = result
            return nil
        }
        if let continuation {
            continuation.resume(with: result)
        }
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }
}

// MARK: - URL policy

/// Deterministic, offline URL policy for Web fetch destinations. Unlike the
/// Browser feature there is no local-development use case here, so loopback is
/// restricted together with RFC1918, link-local, multicast, and otherwise
/// non-public destinations. Private-network access requires an explicit
/// host-level opt-in; the model cannot weaken this through a tool argument.
struct WebURLPolicy: Sendable {
    let allowsPrivateNetwork: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let rawValue = environment["ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.allowsPrivateNetwork = ["1", "true", "yes", "on"].contains(rawValue)
    }

    func validate(_ rawURL: String) throws -> URL {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw WebURLPolicyError.emptyURL
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let url = components.url
        else {
            throw WebURLPolicyError.invalidURL(value)
        }
        guard ["http", "https"].contains(scheme) else {
            throw WebURLPolicyError.unsupportedScheme(components.scheme ?? "")
        }
        guard components.user == nil, components.password == nil else {
            throw WebURLPolicyError.credentialsNotAllowed(value)
        }
        guard let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty
        else {
            throw WebURLPolicyError.missingHost(value)
        }

        let host = normalizedHost(rawHost)
        guard allowsPrivateNetwork || !isRestricted(host: host) else {
            throw WebURLPolicyError.restrictedHost(rawHost)
        }
        return url
    }

    /// Rechecks a numeric address returned by a host resolver immediately
    /// before a request is allowed to proceed.
    func validateResolvedAddress(_ rawAddress: String) throws {
        let address = normalizedHost(rawAddress)
        guard !address.isEmpty else {
            throw WebURLPolicyError.restrictedHost(rawAddress)
        }
        guard allowsPrivateNetwork || !isRestricted(host: address) else {
            throw WebURLPolicyError.restrictedHost(rawAddress)
        }
    }

    func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if host == "::1" {
            return true
        }
        if let octets = ipv4Octets(host) {
            return octets[0] == 127
        }
        guard let bytes = ipv6Bytes(host) else {
            return false
        }
        let isIPv4Compatible = bytes[0..<12].allSatisfy { $0 == 0 }
        let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        return (isIPv4Compatible || isIPv4Mapped) && bytes[12] == 127
    }

    private func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func isRestricted(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if host == "local" || host.hasSuffix(".local") {
            return true
        }
        if let octets = ipv4Octets(host) {
            return isRestrictedIPv4(octets)
        }
        if isAmbiguousNumericHost(host) {
            return true
        }
        return isRestrictedIPv6(host)
    }

    private func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        var result = [UInt8]()
        result.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty,
                  !(part.count > 1 && part.first == "0"),
                  part.allSatisfy({ $0.isNumber }),
                  let value = UInt8(part)
            else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    private func isRestrictedIPv4(_ octets: [UInt8]) -> Bool {
        guard octets.count == 4 else { return true }
        let first = octets[0]
        let second = octets[1]
        switch first {
        case 0, 10, 224...255:
            return true
        case 100 where (64...127).contains(second):
            return true
        case 127:
            return true
        case 169 where second == 254:
            return true
        case 172 where (16...31).contains(second):
            return true
        case 192 where second == 0 || second == 168:
            return true
        case 198 where second == 18 || second == 19 || second == 51:
            return true
        case 203 where second == 0:
            return true
        default:
            return false
        }
    }

    private func isRestrictedIPv6(_ host: String) -> Bool {
        guard host.contains(":"),
              let bytes = ipv6Bytes(host)
        else {
            return false
        }

        // :: (unspecified) and ::1 (loopback) are not public destinations.
        if bytes.allSatisfy({ $0 == 0 }) {
            return true
        }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 {
            return true
        }
        // Link-local fe80::/10, legacy site-local fec0::/10, unique-local
        // fc00::/7, and multicast ff00::/8 are not public destinations.
        if bytes[0] == 0xfe {
            let scope = bytes[1] & 0xc0
            if scope == 0x80 || scope == 0xc0 {
                return true
            }
        }
        if (bytes[0] & 0xfe) == 0xfc || bytes[0] == 0xff {
            return true
        }

        // IPv4-compatible and IPv4-mapped literals can encode restricted IPv4
        // targets without a dotted suffix (for example ::ffff:a00:1).
        let hasIPv4CompatiblePrefix = bytes[0..<12].allSatisfy { $0 == 0 }
        let hasIPv4MappedPrefix = bytes[0..<10].allSatisfy { $0 == 0 }
            && bytes[10] == 0xff
            && bytes[11] == 0xff
        if hasIPv4CompatiblePrefix || hasIPv4MappedPrefix {
            let octets = Array(bytes[12..<16])
            return isRestrictedIPv4(octets)
        }
        return false
    }

    private func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let parsed = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { rawBuffer in
            Array(rawBuffer.prefix(16))
        }
    }

    private func isAmbiguousNumericHost(_ host: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "0123456789abcdefx.:[]")
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
        else {
            return false
        }
        // Canonical IPv4 and IPv6 forms were handled above. Anything else made
        // exclusively from numeric-address characters may be accepted by the
        // network stack as an alternative literal representation, so fail
        // closed.
        return ipv4Octets(host) == nil && !host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).contains(":")
    }
}

// MARK: - Request policy

/// Validates URLs the Web feature is about to request: the initial fetch URL
/// and every redirect hop. Mirrors BrowserNetworkRequestPolicy in BrowserTools
/// without its local-development loopback allowance, because web.fetch has no
/// legitimate loopback use.
struct WebNetworkRequestPolicy: Sendable {
    let urlPolicy: WebURLPolicy
    let resolver: any WebHostResolving

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolver: any WebHostResolving = WebSystemHostResolver()
    ) {
        self.urlPolicy = WebURLPolicy(environment: environment)
        self.resolver = resolver
    }

    init(
        urlPolicy: WebURLPolicy,
        resolver: any WebHostResolving
    ) {
        self.urlPolicy = urlPolicy
        self.resolver = resolver
    }

    func validateRequestURL(_ rawURL: String) throws {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw WebNetworkGuardError.unsupportedRequestScheme("<missing>")
        }

        switch scheme {
        case "http", "https":
            break
        default:
            throw WebNetworkGuardError.unsupportedRequestScheme(scheme)
        }

        guard let requestURL = components.url else {
            throw WebNetworkGuardError.unsupportedRequestScheme(scheme)
        }
        let validatedURL = try urlPolicy.validate(requestURL.absoluteString)
        guard let host = validatedURL.host, !host.isEmpty else {
            throw WebNetworkGuardError.unresolvedHost(components.host ?? "")
        }
        let isExplicitLoopback = urlPolicy.isLoopbackHost(host)
        let addresses = try resolver.resolve(host: host)
        for address in addresses {
            if isExplicitLoopback {
                // The host name is already loopback; the address must be too.
                guard urlPolicy.isLoopbackHost(address) else {
                    throw WebNetworkGuardError.unexpectedResolvedLoopback(
                        WebNetworkURLRedaction.apply(to: rawURL)
                    )
                }
            } else if urlPolicy.isLoopbackHost(address) {
                // A public-looking name resolved to loopback (rebinding).
                throw WebNetworkGuardError.unexpectedResolvedLoopback(
                    WebNetworkURLRedaction.apply(to: rawURL)
                )
            }
            try urlPolicy.validateResolvedAddress(address)
        }
    }

    /// Async counterpart of ``validateRequestURL(_:)`` that resolves the
    /// request host off the cooperative thread pool so a slow or blocking DNS
    /// lookup cannot stall request interception. It is cancellation-aware.
    func validateRequestURLOffloaded(_ rawURL: String) async throws {
        try Task.checkCancellation()

        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw WebNetworkGuardError.unsupportedRequestScheme("<missing>")
        }

        switch scheme {
        case "http", "https":
            break
        default:
            throw WebNetworkGuardError.unsupportedRequestScheme(scheme)
        }

        guard let requestURL = components.url else {
            throw WebNetworkGuardError.unsupportedRequestScheme(scheme)
        }
        let validatedURL = try urlPolicy.validate(requestURL.absoluteString)
        guard let host = validatedURL.host, !host.isEmpty else {
            throw WebNetworkGuardError.unresolvedHost(components.host ?? "")
        }
        let isExplicitLoopback = urlPolicy.isLoopbackHost(host)

        let addresses = try await resolveHostOffloaded(host)

        let redactedURL = WebNetworkURLRedaction.apply(to: rawURL)
        for address in addresses {
            if isExplicitLoopback {
                guard urlPolicy.isLoopbackHost(address) else {
                    throw WebNetworkGuardError.unexpectedResolvedLoopback(redactedURL)
                }
            } else if urlPolicy.isLoopbackHost(address) {
                throw WebNetworkGuardError.unexpectedResolvedLoopback(redactedURL)
            }
            try urlPolicy.validateResolvedAddress(address)
        }
    }

    /// Runs the blocking resolver on a global dispatch queue (never on the
    /// cooperative thread pool) and resumes the awaiting continuation either
    /// with the resolver's result or, if the surrounding task is cancelled
    /// first, with ``CancellationError``.
    private func resolveHostOffloaded(_ host: String) async throws -> [String] {
        let box = WebOffloadResolutionBox()
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

// MARK: - Redirect guard

/// URLSession delegate that applies the request policy to every HTTP redirect
/// hop. A denied redirect fails the whole task; URLSession surfaces the thrown
/// policy error to the caller instead of silently following the redirect.
final class WebRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: WebNetworkRequestPolicy

    init(policy: WebNetworkRequestPolicy) {
        self.policy = policy
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let rawURL = request.url?.absoluteString ?? ""
        DispatchQueue.global(qos: .userInitiated).async { [policy] in
            do {
                try policy.validateRequestURL(rawURL)
                completionHandler(request)
            } catch {
                completionHandler(nil)
            }
        }
    }
}

// MARK: - Redaction

/// Minimal URL redaction for policy diagnostics, mirroring the Browser
/// feature's approach: credentials and fragments are dropped, sensitive query
/// values are masked, and oversized or malformed URLs are fully redacted.
enum WebNetworkURLRedaction {
    private static let maximumRawURLBytes = 8 * 1_024
    private static let sensitiveQueryNameFragments = [
        "auth", "bearer", "code", "cookie", "credential", "key", "password",
        "proxy", "secret", "session", "sig", "signature", "token",
    ]

    static func apply(to rawURL: String) -> String {
        guard rawURL.lengthOfBytes(using: .utf8) <= maximumRawURLBytes else {
            return "<redacted-url>"
        }
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            return "<redacted-url>"
        }
        if scheme == "data" || scheme == "blob" {
            return "\(scheme):[redacted]"
        }

        components.user = nil
        components.password = nil
        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                let normalizedName = item.name.lowercased()
                guard !sensitiveQueryNameFragments.contains(where: normalizedName.contains) else {
                    return URLQueryItem(name: item.name, value: "[redacted]")
                }
                return item
            }
        } else if components.query != nil {
            components.query = nil
        }

        guard let result = components.string else { return "<redacted-url>" }
        if result.lengthOfBytes(using: .utf8) > 2_048 {
            return String(result.prefix(2_048)) + "…"
        }
        return result
    }
}
