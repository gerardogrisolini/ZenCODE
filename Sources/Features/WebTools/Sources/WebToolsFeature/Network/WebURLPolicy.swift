//  Offline public-destination URL policy for web.fetch.

import FeatureKit
import Foundation

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
        guard !value.isEmpty else { throw WebURLPolicyError.emptyURL }
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
        guard allowsPrivateNetwork || !isRestricted(host: host) else { throw WebURLPolicyError.restrictedHost(rawHost) }
        return url
    }

    /// Rechecks a numeric address returned by a host resolver immediately
    /// before a request is allowed to proceed.
    func validateResolvedAddress(_ rawAddress: String) throws {
        let address = normalizedHost(rawAddress)
        guard !address.isEmpty else { throw WebURLPolicyError.restrictedHost(rawAddress) }
        guard allowsPrivateNetwork || !isRestricted(host: address) else {
            throw WebURLPolicyError.restrictedHost(rawAddress)
        }
    }

    func isLoopbackHost(_ rawHost: String) -> Bool {
        let host = normalizedHost(rawHost)
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return true
        }
        if let octets = FeatureIPAddress.parseDottedQuad(host) ?? FeatureIPAddress.parseIPv4Literal(host) {
            return FeatureIPAddress.classifyIPv4(octets) == .loopback
        }
        // Only IPv4-compatible (`::a.b.c.d`) and IPv4-mapped (`::ffff:a.b.c.d`)
        // literals carry a loopback of this host; a 127 address relayed through
        // 6to4 or NAT64 is not loopback and stays restricted.
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

    /// Every non-public classification, loopback included, is restricted:
    /// web.fetch has no local-development use case.
    private func isRestricted(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "local" || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":") {
            // A host containing ':' can only be an IPv6 literal. Anything the
            // platform cannot parse (malformed literals, and zone identifiers
            // where inet_pton rejects them) fails closed: it can never denote
            // a public destination.
            guard let bytes = FeatureIPAddress.parseIPv6(host) else { return true }
            return FeatureIPAddress.classifyIPv6(bytes) != .publicAddress
        }
        if let octets = FeatureIPAddress.parseDottedQuad(host) {
            return FeatureIPAddress.classifyIPv4(octets) != .publicAddress
        }
        if FeatureIPAddress.endsInNumber(host) {
            // Browsers and the C resolver treat this as an IPv4 literal (octal,
            // hex, short or decimal form) rather than a DNS name. Evaluate the
            // address it denotes; an unparsable candidate fails closed.
            guard let octets = FeatureIPAddress.parseIPv4Literal(host) else { return true }
            return FeatureIPAddress.classifyIPv4(octets) != .publicAddress
        }
        return false
    }
}
