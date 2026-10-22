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
        if let octets = ipv4Octets(host) ?? Self.parseIPv4Literal(host) {
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

    /// WHATWG URL "ends in a number": the last label is all ASCII digits or
    /// `0x` followed by hex digits (possibly empty). Such hosts are IPv4
    /// literal candidates and are never sent to DNS by browsers.
    static func endsInNumber(_ host: String) -> Bool {
        guard let last = host.split(separator: ".", omittingEmptySubsequences: false).last, !last.isEmpty else {
            return false
        }
        if last.allSatisfy(\.isASCIIDigit) { return true }
        if last.hasPrefix("0x") {
            return last.dropFirst(2).allSatisfy(\.isASCIIHexDigit)
        }
        return false
    }

    /// Parses every IPv4 literal form accepted by `inet_aton` and the WHATWG
    /// URL host parser (octal `0177.0.0.1`, hex `0x7f.1`, decimal
    /// `2130706433`, short `127.1`), returning the four octets or nil when the
    /// value is not a valid IPv4 literal. Callers reject nil fail-closed when
    /// the host ends in a number.
    static func parseIPv4Literal(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), !parts.contains(where: \.isEmpty) else { return nil }
        var numbers = [UInt64]()
        for part in parts {
            guard let number = parseIPv4Number(part) else { return nil }
            numbers.append(number)
        }
        let last = numbers.removeLast()
        guard numbers.allSatisfy({ $0 <= 255 }) else { return nil }
        let remaining = 4 - numbers.count
        guard last < (UInt64(1) << (8 * UInt64(remaining))) else { return nil }
        var value: UInt64 = 0
        for number in numbers {
            value = (value << 8) | number
        }
        value = (value << (8 * UInt64(remaining))) | last
        return [
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff),
        ]
    }

    private static func parseIPv4Number(_ part: Substring) -> UInt64? {
        var digits = part
        var radix = 10
        if digits.hasPrefix("0x") {
            digits = digits.dropFirst(2)
            radix = 16
            if digits.isEmpty { return 0 }
        } else if digits.count > 1, digits.first == "0" {
            digits = digits.dropFirst()
            radix = 8
        }
        // `UInt64(_:radix:)` accepts a leading sign; an address label never has one.
        guard !digits.isEmpty, digits.count <= 16, digits.allSatisfy(\.isASCIIHexDigit) else { return nil }
        return UInt64(digits, radix: radix)
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
        if host.contains(":") {
            return isRestrictedIPv6(host)
        }
        if let octets = ipv4Octets(host) {
            return isRestrictedIPv4(octets)
        }
        if Self.endsInNumber(host) {
            // Browsers and the C resolver treat this as an IPv4 literal (octal,
            // hex, short or decimal form) rather than a DNS name. Evaluate the
            // address it denotes; an unparsable candidate fails closed.
            guard let octets = Self.parseIPv4Literal(host) else { return true }
            return isRestrictedIPv4(octets)
        }
        return false
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
        // A host containing ':' can only be an IPv6 literal. Anything that
        // does not parse (zone identifiers such as fe80::1%en0, malformed
        // literals) fails closed: it can never denote a public destination.
        guard let bytes = ipv6Bytes(host) else { return true }

        // :: (unspecified) and ::1 (loopback) are not public destinations.
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] <= 1 {
            return true
        }
        // 100::/64 discard-only (RFC 6666).
        if bytes[0] == 0x01 && bytes[1..<8].allSatisfy({ $0 == 0 }) {
            return true
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            // 2001:db8::/32 documentation, 2001:2::/48 benchmarking,
            // 2001:10::/28 and 2001:20::/28 ORCHID are not routable.
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return true }
            if bytes[2] == 0x00 && bytes[3] == 0x02 && bytes[4] == 0 && bytes[5] == 0 { return true }
            if bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x10 { return true }
            if bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x20 { return true }
        }
        // 6to4 (2002:a.b.c.d::/48) embeds the IPv4 relay in bytes 2..5.
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return isRestrictedIPv4(Array(bytes[2..<6]))
        }
        // NAT64 well-known prefix 64:ff9b::/96 embeds IPv4 in the last four
        // bytes; 64:ff9b:1::/48 is the local-use prefix (RFC 8215).
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b {
            if bytes[4] == 0 && bytes[5] == 1 { return true }
            if bytes[4..<12].allSatisfy({ $0 == 0 }) {
                return isRestrictedIPv4(Array(bytes[12..<16]))
            }
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

}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIHexDigit: Bool { isASCII && isHexDigit }
}
