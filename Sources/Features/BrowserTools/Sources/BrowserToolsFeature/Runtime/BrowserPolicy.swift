//
//  BrowserPolicy.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import FeatureKit
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
/// local development servers. RFC1918, link-local, multicast, the other
/// non-public ranges classified by FeatureKit (including non-public IPv4
/// embedded through NAT64 or 6to4), and ambiguous numeric hosts require an
/// explicit environment-level opt-in; the model cannot weaken this policy
/// through a tool argument.
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
        guard !value.isEmpty else { throw BrowserURLPolicyError.emptyURL }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let url = components.url
        else {
            throw BrowserURLPolicyError.invalidURL(value)
        }
        guard ["http", "https"].contains(scheme) else { throw BrowserURLPolicyError.unsupportedScheme(components.scheme ?? "") }
        guard components.user == nil, components.password == nil else { throw BrowserURLPolicyError.credentialsNotAllowed(value) }
        guard let rawHost = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty
        else {
            throw BrowserURLPolicyError.missingHost(value)
        }

        let host = normalizedHost(rawHost)
        guard allowsPrivateNetwork || !isRestricted(host: host) else { throw BrowserURLPolicyError.restrictedHost(rawHost) }
        return url
    }

    /// Rechecks a numeric address returned by a host resolver. The direct URL
    /// validation above intentionally remains deterministic/offline for unit
    /// tests; a network guard calls this method immediately before Chrome is
    /// allowed to continue an intercepted request.
    func validateResolvedAddress(_ rawAddress: String) throws {
        let address = normalizedHost(rawAddress)
        guard !address.isEmpty else { throw BrowserURLPolicyError.restrictedHost(rawAddress) }
        guard allowsPrivateNetwork || !isRestricted(host: address) else { throw BrowserURLPolicyError.restrictedHost(rawAddress) }
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
        if let octets = FeatureIPAddress.parseDottedQuad(host) {
            return FeatureIPAddress.classifyIPv4(octets) == .loopback
        }
        // Only IPv4-compatible (`::a.b.c.d`) and IPv4-mapped (`::ffff:a.b.c.d`)
        // literals carry a loopback of this host. A 127 address relayed through
        // 6to4 or NAT64 is not local development and stays restricted.
        guard let bytes = FeatureIPAddress.parseIPv6(host),
              let embedded = FeatureIPAddress.embeddedIPv4(in: bytes),
              embedded.kind == .compatible || embedded.kind == .mapped
        else {
            return false
        }
        return FeatureIPAddress.classifyIPv4(embedded.octets) == .loopback
    }

    private func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    /// Loopback recognised by ``isLoopbackHost(_:)`` is the local-development
    /// exception; every other non-public classification is restricted.
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
        if let octets = FeatureIPAddress.parseDottedQuad(host) {
            return FeatureIPAddress.classifyIPv4(octets) != .publicAddress
        }
        if isAmbiguousNumericHost(host) {
            return true
        }
        return isRestrictedIPv6(host)
    }

    private func isRestrictedIPv6(_ host: String) -> Bool {
        guard host.contains(":") else { return false }
        // A colon can only belong to an IPv6 literal here (URLComponents never
        // leaves a port in the host). Anything the platform cannot parse, such
        // as a malformed literal or a zone identifier where inet_pton rejects
        // it, cannot be classified and must fail closed.
        guard let bytes = FeatureIPAddress.parseIPv6(host) else { return true }
        // Recognised loopback literals returned above. A loopback spelling the
        // host policy does not recognise (`0:0:0:0:0:0:0:1`) fails closed with
        // every other non-public classification.
        return FeatureIPAddress.classifyIPv6(bytes) != .publicAddress
    }

    /// Chrome parses a host as an IPv4 address whenever its last dot-separated
    /// label "ends in a number" (WHATWG URL): all decimal digits, or `0x`
    /// followed by hexadecimal digits. Canonical dotted-quad literals were
    /// classified already, so any other host of that shape is either an
    /// alternative literal (octal/hex/short/decimal forms such as
    /// `0177.0.0.1`, `0x7f.1`, or `2130706433`) or an invalid URL; both fail
    /// closed. Ordinary hostnames whose labels merely use hexadecimal letters
    /// (`adac.de`, `abc.de`) are not numeric and stay subject to the normal
    /// resolved-address checks instead.
    private func isAmbiguousNumericHost(_ host: String) -> Bool {
        guard !host.isEmpty,
              !host.contains(":"),
              FeatureIPAddress.parseDottedQuad(host) == nil
        else {
            return false
        }
        return FeatureIPAddress.endsInNumber(host)
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
