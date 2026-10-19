//  Offline public-destination URL policy for web.fetch.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
        if let octets = ipv4Octets(host) {
            return octets[0] == 127
        }
        guard let bytes = ipv6Bytes(host) else { return false }
        return embedsIPv4(bytes) && bytes[12] == 127
    }

    /// True for IPv4-compatible (`::a.b.c.d`) and IPv4-mapped (`::ffff:a.b.c.d`) literals.
    private func embedsIPv4(_ bytes: [UInt8]) -> Bool {
        bytes[0..<12].allSatisfy { $0 == 0 }
            || (bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff)
    }

    private func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private func isRestricted(host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host == "local" || host.hasSuffix(".local") {
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
        guard parts.count == 4 else { return nil }
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
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] <= 1 {
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
        return embedsIPv4(bytes) && isRestrictedIPv4(Array(bytes[12..<16]))
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
