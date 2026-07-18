//
//  BrowserPolicy.swift
//  BrowserToolsFeature
//

import Foundation

/// Validates navigation destinations before they reach Chrome. The Browser
/// feature remains opt-in, but web content is still untrusted and must not be
/// able to turn a normal navigation into an accidental private-network probe.
enum BrowserURLPolicyError: LocalizedError, Equatable, Sendable {
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
        case let .credentialsNotAllowed(value):
            "URLs containing embedded credentials are not allowed: \(value)"
        case let .restrictedHost(host):
            "Navigation to the restricted host '\(host)' is disabled. Set ZENCODE_BROWSER_ALLOW_PRIVATE_NETWORK=1 only when access to a trusted private network is required."
        }
    }
}

/// A deliberately small, deterministic policy for direct Browser navigations.
///
/// Loopback remains available by default because Browser is used to inspect
/// local development servers. RFC1918, link-local, multicast and ambiguous
/// numeric hosts require an explicit environment-level opt-in; the model cannot
/// weaken this policy through a tool argument.
struct BrowserURLPolicy: Sendable {
    let allowsPrivateNetwork: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let rawValue = environment["ZENCODE_BROWSER_ALLOW_PRIVATE_NETWORK"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        self.allowsPrivateNetwork = ["1", "true", "yes", "on"].contains(rawValue)
    }

    func validate(_ rawURL: String) throws -> URL {
        let value = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BrowserURLPolicyError.emptyURL
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let url = components.url
        else {
            throw BrowserURLPolicyError.invalidURL(value)
        }
        guard ["http", "https"].contains(scheme) else {
            throw BrowserURLPolicyError.unsupportedScheme(components.scheme ?? "")
        }
        guard components.user == nil, components.password == nil else {
            throw BrowserURLPolicyError.credentialsNotAllowed(value)
        }
        guard let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty
        else {
            throw BrowserURLPolicyError.missingHost(value)
        }

        let host = rawHost.lowercased()
        guard allowsPrivateNetwork || !isRestricted(host: host) else {
            throw BrowserURLPolicyError.restrictedHost(rawHost)
        }
        return url
    }

    private func isRestricted(host: String) -> Bool {
        if isLoopback(host: host) {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return false
        }
        if host.hasSuffix(".local") {
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

    private func isLoopback(host: String) -> Bool {
        if host == "::1" || host == "[::1]" {
            return true
        }
        guard let octets = ipv4Octets(host) else {
            return false
        }
        return octets[0] == 127
    }

    private func ipv4Octets(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else {
            return nil
        }
        var result: [UInt8] = []
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
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard normalized.contains(":") else {
            return false
        }
        if normalized == "::" || normalized.hasPrefix("fe80:") || normalized.hasPrefix("fc") || normalized.hasPrefix("fd") {
            return true
        }
        if let mappedRange = normalized.range(of: "::ffff:"),
           let octets = ipv4Octets(String(normalized[mappedRange.upperBound...])),
           isRestrictedIPv4(octets) || octets[0] == 127
        {
            return true
        }
        return false
    }

    private func isAmbiguousNumericHost(_ host: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "0123456789abcdefx.:[]")
        guard !host.isEmpty,
              host.unicodeScalars.allSatisfy({ allowedCharacters.contains($0) })
        else {
            return false
        }
        // Canonical IPv4 and IPv6 forms were handled above. Anything else made
        // exclusively from numeric-address characters may be accepted by Chrome
        // as an alternative literal representation, so fail closed.
        return ipv4Octets(host) == nil && !host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).contains(":")
    }
}

/// The legacy Google search flow may dismiss Google's own consent UI, but it
/// must never turn a redirected or otherwise unrelated page into an automatic
/// click target. Regional Google domains intentionally fall back to visible
/// user interaction rather than broadening this trust boundary.
enum BrowserGoogleConsentOriginPolicy {
    static func allows(host: String) -> Bool {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized == "google.com" || normalized.hasSuffix(".google.com")
    }
}
