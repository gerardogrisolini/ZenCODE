//  Network guard errors and DNS resolution for the Web feature.

import FeatureKit
import Foundation

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
    case tooManyRedirects(Int)
    case blockedRedirect(String, underlying: String)
    case contentBlockerUnavailable(String)

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
        case let .tooManyRedirects(limit):
            "Web tools stopped following redirects after \(limit) hops."
        case let .blockedRedirect(url, underlying):
            "Web tools blocked a redirect to '\(url)': \(underlying)"
        case let .contentBlockerUnavailable(reason):
            "Web tools could not install the WebKit content blocker that keeps subresource loads on public hosts, so rendering was refused: \(reason)"
        }
    }
}

/// A synchronous resolver makes the security decision deterministic and lets
/// unit tests inject fixed DNS answers. It mirrors BrowserHostResolving in
/// BrowserTools and is applied immediately before a request continues; it
/// reduces DNS-rebinding exposure but cannot pin the eventual transport
/// connection without a proxy/firewall.
protocol WebHostResolving: Sendable {
    func resolve(host: String) throws -> [String]
}

/// System resolution through FeatureKit's policy-free
/// ``FeatureSystemHostResolver``, with its neutral errors mapped onto the Web
/// feature's own messages.
struct WebSystemHostResolver: WebHostResolving {
    func resolve(host: String) throws -> [String] {
        do {
            return try FeatureSystemHostResolver().resolve(host: host)
        } catch {
            switch error {
            case .unresolvedHost:
                throw WebNetworkGuardError.unresolvedHost(host)
            case .noResolvedAddresses:
                throw WebNetworkGuardError.noResolvedAddresses(host)
            }
        }
    }
}
