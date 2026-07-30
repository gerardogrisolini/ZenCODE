//
//  BrowserPolicy.swift
//  BrowserToolsFeature
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        case .credentialsNotAllowed:
            "URLs containing embedded credentials are not allowed."
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

        let host = normalizedHost(rawHost)
        guard allowsPrivateNetwork || !isRestricted(host: host) else {
            throw BrowserURLPolicyError.restrictedHost(rawHost)
        }
        return url
    }

    /// Rechecks a numeric address returned by a host resolver. The direct URL
    /// validation above intentionally remains deterministic/offline for unit
    /// tests; a network guard calls this method immediately before Chrome is
    /// allowed to continue an intercepted request.
    func validateResolvedAddress(_ rawAddress: String) throws {
        let address = normalizedHost(rawAddress)
        guard !address.isEmpty else {
            throw BrowserURLPolicyError.restrictedHost(rawAddress)
        }
        guard allowsPrivateNetwork || !isRestricted(host: address) else {
            throw BrowserURLPolicyError.restrictedHost(rawAddress)
        }
    }

    /// Identifies the explicitly local destinations Browser supports for web
    /// development. A network guard uses this separately from the general URL
    /// policy so a public document cannot silently pivot into loopback merely
    /// because local development itself is allowed.
    func isLoopbackURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              let host = components.host
        else {
            return false
        }
        return isLoopbackHost(host)
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
        if isLoopbackHost(host) {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return false
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
        guard host.contains(":"),
              let bytes = ipv6Bytes(host)
        else {
            return false
        }

        // :: is unspecified; ::1 was handled as loopback above.
        if bytes.allSatisfy({ $0 == 0 }) {
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
