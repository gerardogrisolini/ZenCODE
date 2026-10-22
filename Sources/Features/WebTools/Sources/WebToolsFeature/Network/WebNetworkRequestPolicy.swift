//  Request policy, redirect guard and URL redaction applied to every fetch hop.

import Dispatch
import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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

    init(urlPolicy: WebURLPolicy, resolver: any WebHostResolving) {
        self.urlPolicy = urlPolicy
        self.resolver = resolver
    }

    @discardableResult
    func validateRequestURL(_ rawURL: String) throws -> URL {
        let (url, host) = try validatedHost(of: rawURL)
        try validate(addresses: try resolver.resolve(host: host), of: host, rawURL: rawURL)
        return url
    }

    /// Async counterpart of ``validateRequestURL(_:)`` that resolves the
    /// request host off the cooperative thread pool so a slow or blocking DNS
    /// lookup cannot stall request interception. It is cancellation-aware.
    func validateRequestURLOffloaded(_ rawURL: String) async throws {
        try Task.checkCancellation()
        let (_, host) = try validatedHost(of: rawURL)
        try validate(addresses: try await resolveHostOffloaded(host), of: host, rawURL: rawURL)
    }

    /// Checks scheme and URL policy, returning the validated URL and the host
    /// that must be resolved.
    private func validatedHost(of rawURL: String) throws -> (URL, String) {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            throw WebNetworkGuardError.unsupportedRequestScheme("<missing>")
        }
        guard ["http", "https"].contains(scheme) else { throw WebNetworkGuardError.unsupportedRequestScheme(scheme) }
        guard let requestURL = components.url else { throw WebNetworkGuardError.unsupportedRequestScheme(scheme) }
        let validatedURL = try urlPolicy.validate(requestURL.absoluteString)
        guard let host = validatedURL.host, !host.isEmpty else {
            throw WebNetworkGuardError.unresolvedHost(components.host ?? "")
        }
        return (validatedURL, host)
    }

    /// A loopback host name must resolve only to loopback, and any other name
    /// must never resolve to loopback (rebinding); every address is then
    /// checked against the private-network policy. An empty answer fails
    /// closed, as in the Browser guard: with nothing to check, nothing is allowed.
    private func validate(addresses: [String], of host: String, rawURL: String) throws {
        guard !addresses.isEmpty else { throw WebNetworkGuardError.noResolvedAddresses(host) }
        let isExplicitLoopback = urlPolicy.isLoopbackHost(host)
        for address in addresses {
            if urlPolicy.isLoopbackHost(address) != isExplicitLoopback {
                throw WebNetworkGuardError.unexpectedResolvedLoopback(WebNetworkURLRedaction.apply(to: rawURL))
            }
            try urlPolicy.validateResolvedAddress(address)
        }
    }

    /// Runs the blocking resolver on a global dispatch queue (never on the
    /// cooperative thread pool) and resumes the awaiting continuation either
    /// with the resolver's result or, if the surrounding task is cancelled
    /// first, with ``CancellationError``.
    private func resolveHostOffloaded(_ host: String) async throws -> [String] {
        let box = WebSingleResumeBox<[String]>()
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

/// URLSession delegate that applies the request policy to every HTTP redirect
/// hop. A denied redirect is not followed: URLSession then delivers the 3xx
/// response itself as the final response, and callers consult
/// ``blockedRedirectError(for:)`` to report the real reason instead of a bare
/// status code. Redirect chains are capped per task so a misbehaving server
/// cannot keep a request alive indefinitely.
class WebRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let maximumRedirects = 10

    private let policy: WebNetworkRequestPolicy
    private let redirectState = Mutex(RedirectState())

    private struct RedirectState: Sendable {
        var redirectCounts: [Int: Int] = [:]
        var blockedErrors: [Int: any Error] = [:]
    }

    init(policy: WebNetworkRequestPolicy) {
        self.policy = policy
        super.init()
    }

    /// The policy error that stopped a redirect of `task`, if any.
    func blockedRedirectError(for task: URLSessionTask) -> (any Error)? {
        redirectState.withLock { $0.blockedErrors[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @Sendable @escaping (URLRequest?) -> Void
    ) {
        let rawURL = request.url?.absoluteString ?? ""
        let taskID = task.taskIdentifier
        let hops = redirectState.withLock { state in
            state.redirectCounts[taskID, default: 0] += 1
            return state.redirectCounts[taskID, default: 0]
        }
        guard hops <= Self.maximumRedirects else {
            redirectState.withLock {
                $0.blockedErrors[taskID] = WebNetworkGuardError.tooManyRedirects(Self.maximumRedirects)
            }
            completionHandler(nil)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [policy] in
            do {
                try policy.validateRequestURL(rawURL)
                completionHandler(request)
            } catch {
                self.redirectState.withLock { $0.blockedErrors[taskID] = error }
                completionHandler(nil)
            }
        }
    }
}

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
        guard rawURL.lengthOfBytes(using: .utf8) <= maximumRawURLBytes else { return "<redacted-url>" }
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
