import Foundation
@testable import BrowserToolsFeature
import Testing

/// Decision the Browser policy takes for one host or resolved address.
/// `loopback` is an allowed host that `isLoopbackHost` reports as loopback:
/// it is reachable only through the local-development capability.
enum BrowserAddressDecision: String, Sendable {
    case allowed
    case blocked
    case loopback
    case blockedLoopback
    case invalid
}

/// One characterization row: the same literal used as a URL host and as an
/// address returned by a resolver.
struct BrowserAddressCase: Sendable, CustomTestStringConvertible {
    let host: String
    let url: BrowserAddressDecision
    let resolved: BrowserAddressDecision
    /// Decision recorded on the original code when it differs: the IPv6
    /// ranges Browser now classifies through FeatureKit like WebTools does.
    let before: BrowserAddressDecision?

    init(_ host: String, _ decision: BrowserAddressDecision, before: BrowserAddressDecision? = nil) {
        self.host = host
        self.url = decision
        self.resolved = decision
        self.before = before
    }

    var urlString: String {
        guard host.contains(":") else { return "http://\(host)/" }
        return "http://[\(host.replacingOccurrences(of: "%", with: "%25"))]/"
    }

    var testDescription: String { host }
}

/// Characterization matrix of the Browser URL policy. Rows with `before:`
/// changed when Browser adopted FeatureKit's IPv6 classification: NAT64,
/// 6to4, discard, documentation, benchmarking, and ORCHID ranges are now
/// blocked as in WebTools. Every other decision is the original one.
@Suite
struct BrowserAddressDecisionMatrixTests {
    static let cases: [BrowserAddressCase] = [
        // Canonical dotted quads: public, including the neighbours of every range.
        BrowserAddressCase("93.184.216.34", .allowed),
        BrowserAddressCase("8.8.8.8", .allowed),
        BrowserAddressCase("1.1.1.1", .allowed),
        BrowserAddressCase("9.255.255.255", .allowed),
        BrowserAddressCase("11.0.0.1", .allowed),
        BrowserAddressCase("100.63.255.255", .allowed),
        BrowserAddressCase("100.128.0.1", .allowed),
        BrowserAddressCase("126.255.255.255", .allowed),
        BrowserAddressCase("128.0.0.1", .allowed),
        BrowserAddressCase("169.253.255.255", .allowed),
        BrowserAddressCase("169.255.0.1", .allowed),
        BrowserAddressCase("172.15.255.255", .allowed),
        BrowserAddressCase("172.32.0.1", .allowed),
        BrowserAddressCase("192.1.0.1", .allowed),
        BrowserAddressCase("192.167.0.1", .allowed),
        BrowserAddressCase("192.169.0.1", .allowed),
        BrowserAddressCase("198.17.255.255", .allowed),
        BrowserAddressCase("198.20.0.1", .allowed),
        BrowserAddressCase("198.50.0.1", .allowed),
        BrowserAddressCase("198.52.0.1", .allowed),
        BrowserAddressCase("203.1.0.1", .allowed),
        BrowserAddressCase("223.255.255.255", .allowed),
        // Canonical dotted quads: every non-public range.
        BrowserAddressCase("0.0.0.0", .blocked),
        BrowserAddressCase("0.1.2.3", .blocked),
        BrowserAddressCase("10.0.0.1", .blocked),
        BrowserAddressCase("10.255.255.255", .blocked),
        BrowserAddressCase("100.64.0.1", .blocked),
        BrowserAddressCase("100.127.255.255", .blocked),
        BrowserAddressCase("169.254.169.254", .blocked),
        BrowserAddressCase("169.254.0.1", .blocked),
        BrowserAddressCase("172.16.0.1", .blocked),
        BrowserAddressCase("172.31.255.255", .blocked),
        BrowserAddressCase("192.0.0.1", .blocked),
        BrowserAddressCase("192.0.2.1", .blocked),
        BrowserAddressCase("192.168.1.1", .blocked),
        BrowserAddressCase("198.18.0.1", .blocked),
        BrowserAddressCase("198.19.255.255", .blocked),
        BrowserAddressCase("198.51.100.1", .blocked),
        BrowserAddressCase("203.0.113.1", .blocked),
        BrowserAddressCase("224.0.0.1", .blocked),
        BrowserAddressCase("239.255.255.255", .blocked),
        BrowserAddressCase("240.0.0.1", .blocked),
        BrowserAddressCase("255.255.255.255", .blocked),
        // Loopback dotted quads stay available for local development.
        BrowserAddressCase("127.0.0.1", .loopback),
        BrowserAddressCase("127.0.1.1", .loopback),
        BrowserAddressCase("127.255.255.254", .loopback),
        BrowserAddressCase("127.0.0.1.", .loopback),
        // Alternative IPv4 literal forms and ambiguous numeric hosts fail closed,
        // whatever address they denote.
        BrowserAddressCase("0177.0.0.1", .blocked),
        BrowserAddressCase("0x7f.1", .blocked),
        BrowserAddressCase("2130706433", .blocked),
        BrowserAddressCase("127.1", .blocked),
        BrowserAddressCase("0x7f000001", .blocked),
        BrowserAddressCase("0X7F000001", .blocked),
        BrowserAddressCase("10.0.1", .blocked),
        BrowserAddressCase("0xa9.0xfe.1.1", .blocked),
        BrowserAddressCase("0251.0376.1.1", .blocked),
        BrowserAddressCase("0", .blocked),
        BrowserAddressCase("1562726098", .blocked),
        BrowserAddressCase("0x5d.0x27.0x7ed2", .blocked),
        BrowserAddressCase("1.0x", .blocked),
        BrowserAddressCase("0x5d27.0x7ed2", .blocked),
        BrowserAddressCase("1.2.3.4.5", .blocked),
        BrowserAddressCase("4294967296", .blocked),
        BrowserAddressCase("256.1", .blocked),
        BrowserAddressCase("1.2.3.256", .blocked),
        BrowserAddressCase("08.1.1.1", .blocked),
        BrowserAddressCase("example.123", .blocked),
        BrowserAddressCase("example.0x", .blocked),
        // Ordinary DNS names, including all-hex labels.
        BrowserAddressCase("example.com", .allowed),
        BrowserAddressCase("abc.de", .allowed),
        BrowserAddressCase("cafe.de", .allowed),
        BrowserAddressCase("0xdead.beef.example", .allowed),
        BrowserAddressCase("example.0x1g", .allowed),
        BrowserAddressCase("localhost.example", .allowed),
        BrowserAddressCase("notlocal", .allowed),
        // Special names.
        BrowserAddressCase("localhost", .loopback),
        BrowserAddressCase("LOCALHOST", .loopback),
        BrowserAddressCase("localhost.", .loopback),
        BrowserAddressCase("app.localhost", .loopback),
        BrowserAddressCase(".localhost", .loopback),
        BrowserAddressCase("local", .blocked),
        BrowserAddressCase(".local", .blocked),
        BrowserAddressCase("service.local", .blocked),
        BrowserAddressCase("service.local.", .blocked),
        // IPv6: unspecified and loopback. Non-canonical spellings of ::1 are not
        // recognised as loopback and fail closed.
        BrowserAddressCase("::", .blocked),
        BrowserAddressCase("::1", .loopback),
        BrowserAddressCase("0:0:0:0:0:0:0:1", .blocked),
        BrowserAddressCase("::0.0.0.1", .blocked),
        // IPv4-mapped and IPv4-compatible: 127 stays loopback.
        BrowserAddressCase("::ffff:10.0.0.1", .blocked),
        BrowserAddressCase("::ffff:a00:1", .blocked),
        BrowserAddressCase("::ffff:127.0.0.1", .loopback),
        BrowserAddressCase("::ffff:7f00:1", .loopback),
        BrowserAddressCase("::ffff:93.184.216.34", .allowed),
        BrowserAddressCase("::ffff:0:0", .blocked),
        BrowserAddressCase("::10.0.0.1", .blocked),
        BrowserAddressCase("::a00:1", .blocked),
        BrowserAddressCase("::127.0.0.1", .loopback),
        BrowserAddressCase("::7f00:1", .loopback),
        BrowserAddressCase("::93.184.216.34", .allowed),
        BrowserAddressCase("::5db8:d822", .allowed),
        // Unique-local, link-local (with and without zone), site-local, multicast.
        BrowserAddressCase("fc00::1", .blocked),
        BrowserAddressCase("fd00::1", .blocked),
        BrowserAddressCase("fdff:ffff::1", .blocked),
        BrowserAddressCase("fe80::1", .blocked),
        BrowserAddressCase("fe90::1", .blocked),
        BrowserAddressCase("febf::1", .blocked),
        BrowserAddressCase("fe80::1%en0", .blocked),
        BrowserAddressCase("fec0::1", .blocked),
        BrowserAddressCase("feff::1", .blocked),
        BrowserAddressCase("fe00::1", .allowed),
        BrowserAddressCase("ff02::1", .blocked),
        BrowserAddressCase("ff05::2", .blocked),
        BrowserAddressCase("ff0e::1", .blocked),
        // NAT64 well-known (64:ff9b::/96) and local-use (64:ff9b:1::/48) prefixes.
        BrowserAddressCase("64:ff9b::a00:1", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b::10.0.0.1", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b::7f00:1", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b::a9fe:a9fe", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b::c0a8:101", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b::5db8:d822", .allowed),
        BrowserAddressCase("64:ff9b:1::1", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b:1:ffff::1", .blocked, before: .allowed),
        BrowserAddressCase("64:ff9b:0:0:1::a00:1", .allowed),
        // 6to4 (2002::/16) with the embedded IPv4 relay.
        BrowserAddressCase("2002:a00:1::1", .blocked, before: .allowed),
        BrowserAddressCase("2002:7f00:1::1", .blocked, before: .allowed),
        BrowserAddressCase("2002:c0a8:101::1", .blocked, before: .allowed),
        BrowserAddressCase("2002:a9fe:a9fe::1", .blocked, before: .allowed),
        BrowserAddressCase("2002:5db8:d822::1", .allowed),
        // Discard-only 100::/64.
        BrowserAddressCase("100::1", .blocked, before: .allowed),
        BrowserAddressCase("100::ffff:ffff:ffff:ffff", .blocked, before: .allowed),
        BrowserAddressCase("100:0:0:1::1", .allowed),
        // Documentation, benchmarking, ORCHID.
        BrowserAddressCase("2001:db8::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:db8:ffff::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:db9::1", .allowed),
        BrowserAddressCase("2001:2::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:2:0:ffff::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:2:1::1", .allowed),
        BrowserAddressCase("2001:10::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:1f::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:20::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:2f::1", .blocked, before: .allowed),
        BrowserAddressCase("2001:30::1", .allowed),
        // Public IPv6.
        BrowserAddressCase("2001:200::1", .allowed),
        BrowserAddressCase("2001:4860:4860::8888", .allowed),
        BrowserAddressCase("2606:2800:220:1:248:1893:25c8:1946", .allowed),
        // Malformed literals fail closed.
        BrowserAddressCase("1:2:3", .blocked),
        BrowserAddressCase("2606:2800:220:1:248:1893:25c8:1946:ffff", .blocked),
    ]

    @Test(arguments: cases)
    func urlAndResolvedAddressDecisionsAreStable(_ row: BrowserAddressCase) {
        let policy = BrowserURLPolicy(environment: [:])
        let loopback = policy.isLoopbackHost(row.host)

        #expect(Self.decision(loopback: loopback) { _ = try policy.validate(row.urlString) } == row.url, "URL \(row.urlString)")
        #expect(Self.decision(loopback: loopback) { try policy.validateResolvedAddress(row.host) } == row.resolved, "resolved \(row.host)")
    }

    @Test
    func casesAreUnique() {
        #expect(Set(Self.cases.map(\.host)).count == Self.cases.count)
    }

    @Test
    func onlyTheAlignedIPv6RangesChangedFromTheBaseline() {
        let changed = Self.cases.filter { $0.before != nil }
        #expect(changed.count == 21)
        #expect(changed.allSatisfy { $0.host.contains(":") && $0.before == .allowed && $0.url == .blocked })
    }

    /// Request-level decisions when a host resolves to a given address, with
    /// and without the local-development loopback capability. A 127 address
    /// relayed through NAT64 or 6to4 is restricted, never loopback, even for a
    /// local-development page; IPv4-mapped 127 stays loopback.
    @Test(arguments: [
        ("probe.example", "93.184.216.34", false, "allowed"),
        ("probe.example", "10.0.0.1", false, "restricted"),
        ("probe.example", "127.0.0.1", false, "unexpectedLoopback"),
        ("probe.example", "::ffff:127.0.0.1", false, "unexpectedLoopback"),
        ("probe.example", "64:ff9b::7f00:1", false, "restricted"), // before: allowed
        ("probe.example", "2002:7f00:1::1", false, "restricted"), // before: allowed
        ("probe.example", "64:ff9b::a00:1", false, "restricted"), // before: allowed
        ("probe.example", "127.0.0.1", true, "unexpectedLoopback"),
        ("localhost", "127.0.0.1", false, "loopbackNotAuthorized"),
        ("localhost", "127.0.0.1", true, "allowed"),
        ("localhost", "::1", true, "allowed"),
        ("localhost", "::ffff:127.0.0.1", true, "allowed"),
        ("localhost", "64:ff9b::7f00:1", true, "restricted"), // before: allowed
        ("localhost", "2002:7f00:1::1", true, "restricted"), // before: allowed
        ("localhost", "93.184.216.34", true, "allowed"),
        ("localhost", "0:0:0:0:0:0:0:1", true, "restricted"),
    ])
    func requestDecisionsAreStable(host: String, address: String, allowsLoopback: Bool, expected: String) {
        let policy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: StaticBrowserHostResolver(addressesByHost: [host: [address]]),
            allowsLoopback: allowsLoopback
        )
        let decision: String
        do {
            try policy.validateRequestURL("https://\(host)/")
            decision = "allowed"
        } catch let error as BrowserURLPolicyError {
            if case .restrictedHost = error { decision = "restricted" } else { decision = "url:\(error)" }
        } catch let error as BrowserNetworkGuardError {
            switch error {
            case .unexpectedResolvedLoopback: decision = "unexpectedLoopback"
            case .loopbackNotAuthorized: decision = "loopbackNotAuthorized"
            default: decision = "guard:\(error)"
            }
        } catch {
            decision = "other:\(error)"
        }
        #expect(decision == expected, "\(host) -> \(address)")
    }

    private static func decision(loopback: Bool, _ body: () throws -> Void) -> BrowserAddressDecision {
        do {
            try body()
            return loopback ? .loopback : .allowed
        } catch let error as BrowserURLPolicyError {
            guard case .restrictedHost = error else { return .invalid }
            return loopback ? .blockedLoopback : .blocked
        } catch {
            return .invalid
        }
    }
}
