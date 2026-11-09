//
//  FeatureIPAddressTests.swift
//  ZenCODE
//

import FeatureKit
import Testing

/// Coverage for the policy-free IP address primitives shared by the network
/// features: parsing of every literal form, embedded IPv4 recognition, and the
/// public / loopback / non-public classification tables.
@Suite
struct FeatureIPAddressTests {
    // MARK: - IPv4 parsing

    @Test
    func dottedQuadAcceptsOnlyCanonicalLiterals() {
        #expect(FeatureIPAddress.parseDottedQuad("93.184.216.34") == [93, 184, 216, 34])
        #expect(FeatureIPAddress.parseDottedQuad("0.0.0.0") == [0, 0, 0, 0])
        #expect(FeatureIPAddress.parseDottedQuad("255.255.255.255") == [255, 255, 255, 255])

        for value in ["256.0.0.1", "01.2.3.4", "0177.0.0.1", "1.2.3", "1.2.3.4.5", "1..2.3", "a.b.c.d",
                      "+1.2.3.4", "0x7f.0.0.1", "127.1", "2130706433", "\u{0661}.2.3.4", "", "::1"]
        {
            #expect(FeatureIPAddress.parseDottedQuad(value) == nil, "\(value)")
        }
    }

    @Test
    func endsInNumberFollowsTheWHATWGRule() {
        for host in ["127.1", "0x7f.1", "1.0x", "example.123", "example.0x", "2130706433", "1.2.3.4"] {
            #expect(FeatureIPAddress.endsInNumber(host), "\(host)")
        }
        for host in ["abc.de", "example.com", "example.0x1g", "cafe", "1.2.3.", "", "\u{0661}"] {
            #expect(!FeatureIPAddress.endsInNumber(host), "\(host)")
        }
    }

    @Test
    func ipv4LiteralParsesEveryAlternativeForm() {
        #expect(FeatureIPAddress.parseIPv4Literal("0177.0.0.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("2130706433") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0x7f.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("127.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0x7f000001") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("10.0.1") == [10, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0xa9.0xfe.1.1") == [169, 254, 1, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("93.184.216.34") == [93, 184, 216, 34])
        #expect(FeatureIPAddress.parseIPv4Literal("1.0x") == [1, 0, 0, 0])
        #expect(FeatureIPAddress.parseIPv4Literal("0") == [0, 0, 0, 0])

        for value in ["1.2.3.4.5", "256.1", "1.2.3.256", "4294967296", "08.1.1.1", "+1.1.1.1", "1.-1.1.1",
                      "0x5d27.0x7ed2", "example.123", "1..1", "", "0x1g"]
        {
            #expect(FeatureIPAddress.parseIPv4Literal(value) == nil, "\(value)")
        }
    }

    // MARK: - IPv6 parsing

    @Test
    func ipv6ParsesPlainLiteralsOnly() {
        #expect(FeatureIPAddress.parseIPv6("::1") == Array(repeating: 0, count: 15) + [1])
        #expect(FeatureIPAddress.parseIPv6("::") == Array(repeating: 0, count: 16))
        #expect(FeatureIPAddress.parseIPv6("2001:db8::1") == [0x20, 0x01, 0x0d, 0xb8] + Array(repeating: 0, count: 11) + [1])
        #expect(FeatureIPAddress.parseIPv6("::ffff:10.0.0.1") == Array(repeating: 0, count: 10) + [0xff, 0xff, 10, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv6("0:0:0:0:0:0:0:1") == FeatureIPAddress.parseIPv6("::1"))

        for value in ["1:2:3", "2606:2800:220:1:248:1893:25c8:1946:ffff", "93.184.216.34", "[::1]", "", "localhost"] {
            #expect(FeatureIPAddress.parseIPv6(value) == nil, "\(value)")
        }
    }

    @Test
    func zonedLinkLocalLiteralsNeverClassifyAsPublic() {
        // glibc rejects a `%zone` suffix; Darwin accepts it and stores the
        // link-local scope in bytes 2..<4. Either way the result is not public.
        for value in ["fe80::1%en0", "fe80::1%25en0", "fe80::1%lo0"] {
            let classification = FeatureIPAddress.parseIPv6(value).map(FeatureIPAddress.classifyIPv6) ?? .nonPublic
            #expect(classification == .nonPublic, "\(value)")
        }
    }

    @Test(arguments: [
        ("::a00:1", FeatureEmbeddedIPv4(kind: .compatible, octets: [10, 0, 0, 1])),
        ("::", FeatureEmbeddedIPv4(kind: .compatible, octets: [0, 0, 0, 0])),
        ("::1", FeatureEmbeddedIPv4(kind: .compatible, octets: [0, 0, 0, 1])),
        ("::ffff:7f00:1", FeatureEmbeddedIPv4(kind: .mapped, octets: [127, 0, 0, 1])),
        ("::ffff:93.184.216.34", FeatureEmbeddedIPv4(kind: .mapped, octets: [93, 184, 216, 34])),
        ("2002:c0a8:101::1", FeatureEmbeddedIPv4(kind: .sixToFour, octets: [192, 168, 1, 1])),
        ("2002:7f00:1:ffff::1", FeatureEmbeddedIPv4(kind: .sixToFour, octets: [127, 0, 0, 1])),
        ("64:ff9b::a00:1", FeatureEmbeddedIPv4(kind: .nat64, octets: [10, 0, 0, 1])),
        ("64:ff9b::93.184.216.34", FeatureEmbeddedIPv4(kind: .nat64, octets: [93, 184, 216, 34])),
    ])
    func embeddedIPv4IsRecognised(literal: String, expected: FeatureEmbeddedIPv4) throws {
        let bytes = try #require(FeatureIPAddress.parseIPv6(literal))
        #expect(FeatureIPAddress.embeddedIPv4(in: bytes) == expected)
    }

    @Test
    func addressesWithoutEmbeddedIPv4AreNotMistaken() throws {
        for literal in ["64:ff9b:1::a00:1", "64:ff9b:0:0:1::a00:1", "2001:db8::a00:1", "::fffe:a00:1", "fe80::a00:1"] {
            let bytes = try #require(FeatureIPAddress.parseIPv6(literal))
            #expect(FeatureIPAddress.embeddedIPv4(in: bytes) == nil, "\(literal)")
        }
        #expect(FeatureIPAddress.embeddedIPv4(in: []) == nil)
        #expect(FeatureIPAddress.embeddedIPv4(in: [0, 0, 0, 0]) == nil)
    }

    // MARK: - Classification

    @Test(arguments: [
        // Public, including the neighbours of every range.
        ([93, 184, 216, 34], FeatureIPAddressClassification.publicAddress),
        ([8, 8, 8, 8], .publicAddress),
        ([9, 255, 255, 255], .publicAddress),
        ([11, 0, 0, 1], .publicAddress),
        ([100, 63, 255, 255], .publicAddress),
        ([100, 128, 0, 1], .publicAddress),
        ([126, 255, 255, 255], .publicAddress),
        ([128, 0, 0, 1], .publicAddress),
        ([169, 253, 0, 1], .publicAddress),
        ([169, 255, 0, 1], .publicAddress),
        ([172, 15, 0, 1], .publicAddress),
        ([172, 32, 0, 1], .publicAddress),
        ([192, 1, 0, 1], .publicAddress),
        ([192, 167, 0, 1], .publicAddress),
        ([192, 169, 0, 1], .publicAddress),
        ([198, 17, 0, 1], .publicAddress),
        ([198, 20, 0, 1], .publicAddress),
        ([198, 50, 0, 1], .publicAddress),
        ([198, 52, 0, 1], .publicAddress),
        ([203, 1, 0, 1], .publicAddress),
        ([223, 255, 255, 255], .publicAddress),
        // Loopback is reported on its own.
        ([127, 0, 0, 1], .loopback),
        ([127, 255, 255, 254], .loopback),
        // Non-public ranges.
        ([0, 0, 0, 0], .nonPublic),
        ([0, 1, 2, 3], .nonPublic),
        ([10, 0, 0, 1], .nonPublic),
        ([100, 64, 0, 1], .nonPublic),
        ([100, 127, 255, 255], .nonPublic),
        ([169, 254, 169, 254], .nonPublic),
        ([172, 16, 0, 1], .nonPublic),
        ([172, 31, 255, 255], .nonPublic),
        ([192, 0, 0, 1], .nonPublic),
        ([192, 0, 2, 1], .nonPublic),
        ([192, 168, 1, 1], .nonPublic),
        ([198, 18, 0, 1], .nonPublic),
        ([198, 19, 255, 255], .nonPublic),
        ([198, 51, 100, 1], .nonPublic),
        ([203, 0, 113, 1], .nonPublic),
        ([224, 0, 0, 1], .nonPublic),
        ([240, 0, 0, 1], .nonPublic),
        ([255, 255, 255, 255], .nonPublic),
        // Wrong length.
        ([], .nonPublic),
        ([93, 184, 216], .nonPublic),
        ([93, 184, 216, 34, 1], .nonPublic),
    ] as [([UInt8], FeatureIPAddressClassification)])
    func ipv4Classification(octets: [UInt8], expected: FeatureIPAddressClassification) {
        #expect(FeatureIPAddress.classifyIPv4(octets) == expected)
    }

    @Test(arguments: [
        // Unspecified and loopback, in any spelling of the same bytes.
        ("::", FeatureIPAddressClassification.nonPublic),
        ("::1", .loopback),
        ("0:0:0:0:0:0:0:1", .loopback),
        ("::0.0.0.1", .loopback),
        // IPv4-compatible and IPv4-mapped take the embedded classification.
        ("::ffff:10.0.0.1", .nonPublic),
        ("::ffff:a00:1", .nonPublic),
        ("::ffff:127.0.0.1", .loopback),
        ("::7f00:1", .loopback),
        ("::ffff:93.184.216.34", .publicAddress),
        ("::5db8:d822", .publicAddress),
        ("::ffff:0:0", .nonPublic),
        ("::2", .nonPublic),
        // Unique-local, link-local, site-local, multicast.
        ("fc00::1", .nonPublic),
        ("fd00::1", .nonPublic),
        ("fe80::1", .nonPublic),
        ("febf::1", .nonPublic),
        ("fec0::1", .nonPublic),
        ("feff::1", .nonPublic),
        ("fe00::1", .publicAddress),
        ("ff02::1", .nonPublic),
        // NAT64: a translated loopback is never this host's loopback.
        ("64:ff9b::a00:1", .nonPublic),
        ("64:ff9b::7f00:1", .nonPublic),
        ("64:ff9b::a9fe:a9fe", .nonPublic),
        ("64:ff9b::5db8:d822", .publicAddress),
        ("64:ff9b:1::1", .nonPublic),
        ("64:ff9b:1:ffff::1", .nonPublic),
        ("64:ff9b:0:0:1::a00:1", .publicAddress),
        // 6to4: a relayed loopback is never this host's loopback.
        ("2002:a00:1::1", .nonPublic),
        ("2002:7f00:1::1", .nonPublic),
        ("2002:c0a8:101::1", .nonPublic),
        ("2002:5db8:d822::1", .publicAddress),
        // Discard, documentation, benchmarking, ORCHID.
        ("100::1", .nonPublic),
        ("100::ffff:ffff:ffff:ffff", .nonPublic),
        ("100:0:0:1::1", .publicAddress),
        ("2001:db8::1", .nonPublic),
        ("2001:db9::1", .publicAddress),
        ("2001:2::1", .nonPublic),
        ("2001:2:0:ffff::1", .nonPublic),
        ("2001:2:1::1", .publicAddress),
        ("2001:10::1", .nonPublic),
        ("2001:1f::1", .nonPublic),
        ("2001:20::1", .nonPublic),
        ("2001:2f::1", .nonPublic),
        ("2001:30::1", .publicAddress),
        // Public.
        ("2001:200::1", .publicAddress),
        ("2001:4860:4860::8888", .publicAddress),
        ("2606:2800:220:1:248:1893:25c8:1946", .publicAddress),
    ] as [(String, FeatureIPAddressClassification)])
    func ipv6Classification(literal: String, expected: FeatureIPAddressClassification) throws {
        let bytes = try #require(FeatureIPAddress.parseIPv6(literal))
        #expect(FeatureIPAddress.classifyIPv6(bytes) == expected)
    }

    @Test
    func ipv6ClassificationOfWrongLengthIsNonPublic() {
        #expect(FeatureIPAddress.classifyIPv6([]) == .nonPublic)
        #expect(FeatureIPAddress.classifyIPv6([93, 184, 216, 34]) == .nonPublic)
        #expect(FeatureIPAddress.classifyIPv6(Array(repeating: 0x20, count: 17)) == .nonPublic)
    }
}
