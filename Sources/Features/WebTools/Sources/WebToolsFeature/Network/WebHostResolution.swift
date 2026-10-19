//  Network guard errors and DNS resolution for the Web feature.

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
        guard !normalizedHost.isEmpty else { throw WebNetworkGuardError.unresolvedHost(host) }
        // RFC 6761 makes these loopback names special. Resolving them
        // explicitly avoids platform resolver differences.
        if normalizedHost.caseInsensitiveCompare("localhost") == .orderedSame
            || normalizedHost.lowercased().hasSuffix(".localhost")
        {
            return ["127.0.0.1", "::1"]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var rawResults: UnsafeMutablePointer<addrinfo>?
        let status = normalizedHost.withCString { hostPointer in
            getaddrinfo(hostPointer, nil, &hints, &rawResults)
        }
        guard status == 0, let firstResult = rawResults else { throw WebNetworkGuardError.unresolvedHost(host) }
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
        guard !values.isEmpty else { throw WebNetworkGuardError.noResolvedAddresses(host) }
        return values
    }
}

/// Thread-safe single-shot holder that bridges a blocking DNS resolver to
/// async Swift code, mirroring BrowserOffloadResolutionBox. Exactly one of the
/// resolver result or a cancellation error resumes the continuation.
final class WebOffloadResolutionBox: Sendable {
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
