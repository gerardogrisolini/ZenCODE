//  Policy-free parsing and classification of numeric IP addresses.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Network scope of a numeric IP address, derived only from the address
/// bytes.
///
/// This is a classification, not a policy: it does not say whether a feature
/// may contact the address. Loopback is reported on its own so every feature
/// decides what it means. Host names (`localhost`, `.local`, …) are never
/// classified here; recognising them is the feature's responsibility.
public enum FeatureIPAddressClassification: Sendable, Equatable {
    /// A globally routable unicast address.
    case publicAddress
    /// `127.0.0.0/8`, `::1`, and the IPv4-compatible or IPv4-mapped forms of
    /// `127.0.0.0/8`. A `127.0.0.0/8` address embedded through 6to4 or NAT64
    /// is not a loopback of this host and is reported as ``nonPublic``.
    case loopback
    /// Any other address that is not a public destination: private, shared,
    /// link-local, unspecified, multicast, reserved, documentation,
    /// benchmarking, ORCHID, discard, or a translation prefix that embeds a
    /// non-public IPv4 address. A value of the wrong length is also reported
    /// here.
    case nonPublic
}

/// An IPv4 address carried inside a 16-byte IPv6 address.
///
/// Recognising the embedding is pure parsing: it neither classifies the
/// embedded address nor decides whether it is acceptable.
public struct FeatureEmbeddedIPv4: Sendable, Equatable {
    /// How the IPv4 address is carried.
    public enum Kind: Sendable, Equatable {
        /// IPv4-compatible `::a.b.c.d`: the first 12 bytes are zero. This also
        /// matches `::` and `::1`, which ``FeatureIPAddress/classifyIPv6(_:)``
        /// classifies before looking at the embedding.
        case compatible
        /// IPv4-mapped `::ffff:a.b.c.d`.
        case mapped
        /// 6to4 `2002:a.b.c.d::/48` (RFC 3056): the relay sits in bytes 2..<6.
        case sixToFour
        /// NAT64 well-known prefix `64:ff9b::/96` (RFC 6052): the IPv4 address
        /// sits in the last four bytes.
        case nat64
    }

    public let kind: Kind
    /// The four embedded IPv4 octets.
    public let octets: [UInt8]

    public init(kind: Kind, octets: [UInt8]) {
        self.kind = kind
        self.octets = octets
    }
}

/// Parsing and classification primitives for numeric IP addresses, shared by
/// network-aware features.
///
/// Every function works on an already normalized value: callers trim
/// whitespace, IPv6 brackets, and trailing dots, and lowercase it. None of
/// these functions applies a policy: they never decide whether a host may be
/// contacted, never give host names such as `localhost` or `.local` any
/// meaning, and never decide what loopback means for a feature.
public enum FeatureIPAddress {
    /// Parses a canonical dotted-quad IPv4 literal (`93.184.216.34`): exactly
    /// four decimal labels in `0...255` without leading zeros. Returns the
    /// four octets, or nil for any other spelling, including the alternative
    /// forms handled by ``parseIPv4Literal(_:)``. It does not classify the
    /// address.
    public static func parseDottedQuad(_ host: String) -> [UInt8]? {
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

    /// WHATWG URL "ends in a number": the last dot-separated label is all
    /// ASCII digits, or `0x` followed by hexadecimal digits (possibly none).
    /// Browsers and the C resolver treat such hosts as IPv4 literal
    /// candidates and never send them to DNS. This only reports the shape; it
    /// does not decide how a feature handles such a host.
    public static func endsInNumber(_ host: String) -> Bool {
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
    /// URL host parser: octal (`0177.0.0.1`), hexadecimal (`0x7f.1`), decimal
    /// (`2130706433`), and short (`127.1`) forms, as well as the canonical
    /// dotted quad. Returns the four octets, or nil when the value is not a
    /// valid IPv4 literal. It does not decide how a feature treats a host
    /// that ends in a number but does not parse.
    public static func parseIPv4Literal(_ host: String) -> [UInt8]? {
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

    /// Parses an IPv6 literal with `inet_pton` and returns its 16 bytes, or
    /// nil when the platform does not accept the value as an IPv6 address
    /// (malformed literals, IPv4 literals, brackets). Zone identifiers are
    /// platform-dependent: glibc rejects a `%zone` suffix, while Darwin
    /// accepts it and stores the scope of a link-local address in bytes
    /// 2..<4, so a zoned link-local literal still classifies as non-public.
    /// It does not classify the address.
    public static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let parsed = host.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parsed == 1 else { return nil }
        return withUnsafeBytes(of: &address) { rawBuffer in
            Array(rawBuffer.prefix(16))
        }
    }

    /// Recognises an IPv4 address embedded in a 16-byte IPv6 address
    /// (IPv4-compatible, IPv4-mapped, 6to4, or NAT64 well-known prefix).
    /// Returns nil for any other address or for a value that is not 16 bytes
    /// long. It does not classify the embedded address.
    public static func embeddedIPv4(in bytes: [UInt8]) -> FeatureEmbeddedIPv4? {
        guard bytes.count == 16 else { return nil }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) {
            return FeatureEmbeddedIPv4(kind: .compatible, octets: Array(bytes[12..<16]))
        }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return FeatureEmbeddedIPv4(kind: .mapped, octets: Array(bytes[12..<16]))
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return FeatureEmbeddedIPv4(kind: .sixToFour, octets: Array(bytes[2..<6]))
        }
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b
            && bytes[4..<12].allSatisfy({ $0 == 0 })
        {
            return FeatureEmbeddedIPv4(kind: .nat64, octets: Array(bytes[12..<16]))
        }
        return nil
    }

    /// Classifies four IPv4 octets. `127.0.0.0/8` is
    /// ``FeatureIPAddressClassification/loopback``; `0/8`, `10/8`,
    /// `100.64/10`, `169.254/16`, `172.16/12`, `192.0/16`, `192.168/16`,
    /// `198.18/15`, `198.51/16`, `203.0/16`, and `224/3` are
    /// ``FeatureIPAddressClassification/nonPublic``; a value that is not four
    /// octets long is non-public. It does not decide whether the address may
    /// be contacted.
    public static func classifyIPv4(_ octets: [UInt8]) -> FeatureIPAddressClassification {
        guard octets.count == 4 else { return .nonPublic }
        let first = octets[0]
        let second = octets[1]
        switch first {
        case 127:
            return .loopback
        case 0, 10, 224...255:
            return .nonPublic
        case 100 where (64...127).contains(second):
            return .nonPublic
        case 169 where second == 254:
            return .nonPublic
        case 172 where (16...31).contains(second):
            return .nonPublic
        case 192 where second == 0 || second == 168:
            return .nonPublic
        case 198 where second == 18 || second == 19 || second == 51:
            return .nonPublic
        case 203 where second == 0:
            return .nonPublic
        default:
            return .publicAddress
        }
    }

    /// Classifies 16 IPv6 bytes.
    ///
    /// `::1` and the IPv4-compatible or IPv4-mapped forms of `127.0.0.0/8` are
    /// loopback. The unspecified address, discard-only `100::/64`,
    /// documentation `2001:db8::/32`, benchmarking `2001:2::/48`, ORCHID
    /// `2001:10::/28` and `2001:20::/28`, NAT64 local-use `64:ff9b:1::/48`,
    /// link-local `fe80::/10`, site-local `fec0::/10`, unique-local
    /// `fc00::/7`, and multicast `ff00::/8` are non-public. IPv4-compatible
    /// and IPv4-mapped addresses take the class of the embedded IPv4 address;
    /// 6to4 and NAT64 addresses are public only when the embedded address is
    /// public, and non-public otherwise. A value that is not 16 bytes long is
    /// non-public. It does not decide whether the address may be contacted.
    public static func classifyIPv6(_ bytes: [UInt8]) -> FeatureIPAddressClassification {
        guard bytes.count == 16 else { return .nonPublic }

        // :: (unspecified) and ::1 (loopback).
        if bytes[0..<15].allSatisfy({ $0 == 0 }) {
            switch bytes[15] {
            case 0: return .nonPublic
            case 1: return .loopback
            default: break
            }
        }
        // 100::/64 discard-only (RFC 6666).
        if bytes[0] == 0x01 && bytes[1..<8].allSatisfy({ $0 == 0 }) {
            return .nonPublic
        }
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            // 2001:db8::/32 documentation, 2001:2::/48 benchmarking,
            // 2001:10::/28 and 2001:20::/28 ORCHID are not routable.
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return .nonPublic }
            if bytes[2] == 0x00 && bytes[3] == 0x02 && bytes[4] == 0 && bytes[5] == 0 { return .nonPublic }
            if bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x10 { return .nonPublic }
            if bytes[2] == 0x00 && (bytes[3] & 0xf0) == 0x20 { return .nonPublic }
        }
        // 64:ff9b:1::/48 is the NAT64 local-use prefix (RFC 8215).
        if bytes[0] == 0x00 && bytes[1] == 0x64 && bytes[2] == 0xff && bytes[3] == 0x9b
            && bytes[4] == 0 && bytes[5] == 1
        {
            return .nonPublic
        }
        // Link-local fe80::/10 and legacy site-local fec0::/10.
        if bytes[0] == 0xfe {
            let scope = bytes[1] & 0xc0
            if scope == 0x80 || scope == 0xc0 {
                return .nonPublic
            }
        }
        // Unique-local fc00::/7 and multicast ff00::/8.
        if (bytes[0] & 0xfe) == 0xfc || bytes[0] == 0xff {
            return .nonPublic
        }

        guard let embedded = embeddedIPv4(in: bytes) else { return .publicAddress }
        let embeddedClassification = classifyIPv4(embedded.octets)
        switch embedded.kind {
        case .compatible, .mapped:
            // These literals can encode any IPv4 target without a dotted
            // suffix (for example ::ffff:a00:1), loopback included.
            return embeddedClassification
        case .sixToFour, .nat64:
            // A relayed or translated address is never this host's loopback.
            return embeddedClassification == .publicAddress ? .publicAddress : .nonPublic
        }
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
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
    var isASCIIHexDigit: Bool { isASCII && isHexDigit }
}
