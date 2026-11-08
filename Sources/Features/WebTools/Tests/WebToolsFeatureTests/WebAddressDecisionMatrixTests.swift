import Foundation
@testable import WebToolsFeature
import Testing

/// Decision the Web policy takes for one host or resolved address.
/// `blockedLoopback` is a restricted host that `isLoopbackHost` also reports
/// as loopback, which drives the DNS-rebinding check of the request policy.
enum WebAddressDecision: String, Sendable {
    case allowed
    case blocked
    case loopback
    case blockedLoopback
    case invalid
}

/// One characterization row: the same literal used as a URL host and as an
/// address returned by a resolver.
struct WebAddressCase: Sendable, CustomTestStringConvertible {
    let host: String
    let url: WebAddressDecision
    let resolved: WebAddressDecision

    init(_ host: String, _ decision: WebAddressDecision) {
        self.init(host, url: decision, resolved: decision)
    }

    init(_ host: String, url: WebAddressDecision, resolved: WebAddressDecision) {
        self.host = host
        self.url = url
        self.resolved = resolved
    }

    var urlString: String {
        guard host.contains(":") else { return "http://\(host)/" }
        return "http://[\(host.replacingOccurrences(of: "%", with: "%25"))]/"
    }

    var testDescription: String { host }
}

/// Characterization matrix of the Web URL policy: every decision recorded
/// here must stay identical when the address primitives move to FeatureKit.
@Suite
struct WebAddressDecisionMatrixTests {
    static let cases: [WebAddressCase] = [
        // Canonical dotted quads: public, including the neighbours of every range.
        WebAddressCase("93.184.216.34", .allowed),
        WebAddressCase("8.8.8.8", .allowed),
        WebAddressCase("1.1.1.1", .allowed),
        WebAddressCase("9.255.255.255", .allowed),
        WebAddressCase("11.0.0.1", .allowed),
        WebAddressCase("100.63.255.255", .allowed),
        WebAddressCase("100.128.0.1", .allowed),
        WebAddressCase("126.255.255.255", .allowed),
        WebAddressCase("128.0.0.1", .allowed),
        WebAddressCase("169.253.255.255", .allowed),
        WebAddressCase("169.255.0.1", .allowed),
        WebAddressCase("172.15.255.255", .allowed),
        WebAddressCase("172.32.0.1", .allowed),
        WebAddressCase("192.1.0.1", .allowed),
        WebAddressCase("192.167.0.1", .allowed),
        WebAddressCase("192.169.0.1", .allowed),
        WebAddressCase("198.17.255.255", .allowed),
        WebAddressCase("198.20.0.1", .allowed),
        WebAddressCase("198.50.0.1", .allowed),
        WebAddressCase("198.52.0.1", .allowed),
        WebAddressCase("203.1.0.1", .allowed),
        WebAddressCase("223.255.255.255", .allowed),
        // Canonical dotted quads: every non-public range.
        WebAddressCase("0.0.0.0", .blocked),
        WebAddressCase("0.1.2.3", .blocked),
        WebAddressCase("10.0.0.1", .blocked),
        WebAddressCase("10.255.255.255", .blocked),
        WebAddressCase("100.64.0.1", .blocked),
        WebAddressCase("100.127.255.255", .blocked),
        WebAddressCase("169.254.169.254", .blocked),
        WebAddressCase("169.254.0.1", .blocked),
        WebAddressCase("172.16.0.1", .blocked),
        WebAddressCase("172.31.255.255", .blocked),
        WebAddressCase("192.0.0.1", .blocked),
        WebAddressCase("192.0.2.1", .blocked),
        WebAddressCase("192.168.1.1", .blocked),
        WebAddressCase("198.18.0.1", .blocked),
        WebAddressCase("198.19.255.255", .blocked),
        WebAddressCase("198.51.100.1", .blocked),
        WebAddressCase("203.0.113.1", .blocked),
        WebAddressCase("224.0.0.1", .blocked),
        WebAddressCase("239.255.255.255", .blocked),
        WebAddressCase("240.0.0.1", .blocked),
        WebAddressCase("255.255.255.255", .blocked),
        // Loopback dotted quads.
        WebAddressCase("127.0.0.1", .blockedLoopback),
        WebAddressCase("127.0.1.1", .blockedLoopback),
        WebAddressCase("127.255.255.254", .blockedLoopback),
        WebAddressCase("127.0.0.1.", .blockedLoopback),
        // Alternative IPv4 literal forms are evaluated as the address they denote.
        WebAddressCase("0177.0.0.1", .blockedLoopback),
        WebAddressCase("0x7f.1", .blockedLoopback),
        WebAddressCase("2130706433", .blockedLoopback),
        WebAddressCase("127.1", .blockedLoopback),
        WebAddressCase("0x7f000001", .blockedLoopback),
        WebAddressCase("0X7F000001", .blockedLoopback),
        WebAddressCase("10.0.1", .blocked),
        WebAddressCase("0xa9.0xfe.1.1", .blocked),
        WebAddressCase("0251.0376.1.1", .blocked),
        WebAddressCase("0", .blocked),
        WebAddressCase("1562726098", .allowed),
        WebAddressCase("0x5d.0x27.0x7ed2", .allowed),
        WebAddressCase("1.0x", .allowed),
        // Hosts that end in a number but are not valid literals fail closed.
        WebAddressCase("0x5d27.0x7ed2", .blocked),
        WebAddressCase("1.2.3.4.5", .blocked),
        WebAddressCase("4294967296", .blocked),
        WebAddressCase("256.1", .blocked),
        WebAddressCase("1.2.3.256", .blocked),
        WebAddressCase("08.1.1.1", .blocked),
        WebAddressCase("example.123", .blocked),
        WebAddressCase("example.0x", .blocked),
        // Ordinary DNS names, including all-hex labels.
        WebAddressCase("example.com", .allowed),
        WebAddressCase("abc.de", .allowed),
        WebAddressCase("cafe.de", .allowed),
        WebAddressCase("0xdead.beef.example", .allowed),
        WebAddressCase("example.0x1g", .allowed),
        WebAddressCase("localhost.example", .allowed),
        WebAddressCase("notlocal", .allowed),
        // Special names.
        WebAddressCase("localhost", .blockedLoopback),
        WebAddressCase("LOCALHOST", .blockedLoopback),
        WebAddressCase("localhost.", .blockedLoopback),
        WebAddressCase("app.localhost", .blockedLoopback),
        WebAddressCase(".localhost", .blockedLoopback),
        WebAddressCase("local", .blocked),
        WebAddressCase(".local", .blocked),
        WebAddressCase("service.local", .blocked),
        WebAddressCase("service.local.", .blocked),
        // IPv6: unspecified and loopback, including non-canonical spellings of ::1.
        WebAddressCase("::", .blocked),
        WebAddressCase("::1", .blockedLoopback),
        WebAddressCase("0:0:0:0:0:0:0:1", .blocked),
        WebAddressCase("::0.0.0.1", .blocked),
        // IPv4-mapped and IPv4-compatible.
        WebAddressCase("::ffff:10.0.0.1", .blocked),
        WebAddressCase("::ffff:a00:1", .blocked),
        WebAddressCase("::ffff:127.0.0.1", .blockedLoopback),
        WebAddressCase("::ffff:7f00:1", .blockedLoopback),
        WebAddressCase("::ffff:93.184.216.34", .allowed),
        WebAddressCase("::ffff:0:0", .blocked),
        WebAddressCase("::10.0.0.1", .blocked),
        WebAddressCase("::a00:1", .blocked),
        WebAddressCase("::127.0.0.1", .blockedLoopback),
        WebAddressCase("::7f00:1", .blockedLoopback),
        WebAddressCase("::93.184.216.34", .allowed),
        WebAddressCase("::5db8:d822", .allowed),
        // Unique-local, link-local (with and without zone), site-local, multicast.
        WebAddressCase("fc00::1", .blocked),
        WebAddressCase("fd00::1", .blocked),
        WebAddressCase("fdff:ffff::1", .blocked),
        WebAddressCase("fe80::1", .blocked),
        WebAddressCase("fe90::1", .blocked),
        WebAddressCase("febf::1", .blocked),
        WebAddressCase("fe80::1%en0", .blocked),
        WebAddressCase("fec0::1", .blocked),
        WebAddressCase("feff::1", .blocked),
        WebAddressCase("fe00::1", .allowed),
        WebAddressCase("ff02::1", .blocked),
        WebAddressCase("ff05::2", .blocked),
        WebAddressCase("ff0e::1", .blocked),
        // NAT64 well-known (64:ff9b::/96) and local-use (64:ff9b:1::/48) prefixes.
        WebAddressCase("64:ff9b::a00:1", .blocked),
        WebAddressCase("64:ff9b::10.0.0.1", .blocked),
        WebAddressCase("64:ff9b::7f00:1", .blocked),
        WebAddressCase("64:ff9b::a9fe:a9fe", .blocked),
        WebAddressCase("64:ff9b::c0a8:101", .blocked),
        WebAddressCase("64:ff9b::5db8:d822", .allowed),
        WebAddressCase("64:ff9b:1::1", .blocked),
        WebAddressCase("64:ff9b:1:ffff::1", .blocked),
        WebAddressCase("64:ff9b:0:0:1::a00:1", .allowed),
        // 6to4 (2002::/16) with the embedded IPv4 relay.
        WebAddressCase("2002:a00:1::1", .blocked),
        WebAddressCase("2002:7f00:1::1", .blocked),
        WebAddressCase("2002:c0a8:101::1", .blocked),
        WebAddressCase("2002:a9fe:a9fe::1", .blocked),
        WebAddressCase("2002:5db8:d822::1", .allowed),
        // Discard-only 100::/64.
        WebAddressCase("100::1", .blocked),
        WebAddressCase("100::ffff:ffff:ffff:ffff", .blocked),
        WebAddressCase("100:0:0:1::1", .allowed),
        // Documentation, benchmarking, ORCHID.
        WebAddressCase("2001:db8::1", .blocked),
        WebAddressCase("2001:db8:ffff::1", .blocked),
        WebAddressCase("2001:db9::1", .allowed),
        WebAddressCase("2001:2::1", .blocked),
        WebAddressCase("2001:2:0:ffff::1", .blocked),
        WebAddressCase("2001:2:1::1", .allowed),
        WebAddressCase("2001:10::1", .blocked),
        WebAddressCase("2001:1f::1", .blocked),
        WebAddressCase("2001:20::1", .blocked),
        WebAddressCase("2001:2f::1", .blocked),
        WebAddressCase("2001:30::1", .allowed),
        // Public IPv6.
        WebAddressCase("2001:200::1", .allowed),
        WebAddressCase("2001:4860:4860::8888", .allowed),
        WebAddressCase("2606:2800:220:1:248:1893:25c8:1946", .allowed),
        // Malformed literals fail closed.
        WebAddressCase("1:2:3", .blocked),
        WebAddressCase("2606:2800:220:1:248:1893:25c8:1946:ffff", .blocked),
    ]

    @Test(arguments: cases)
    func urlAndResolvedAddressDecisionsAreStable(_ row: WebAddressCase) {
        let policy = WebURLPolicy(environment: [:])
        let loopback = policy.isLoopbackHost(row.host)

        #expect(Self.decision(loopback: loopback) { _ = try policy.validate(row.urlString) } == row.url, "URL \(row.urlString)")
        #expect(Self.decision(loopback: loopback) { try policy.validateResolvedAddress(row.host) } == row.resolved, "resolved \(row.host)")
    }

    @Test
    func casesAreUnique() {
        #expect(Set(Self.cases.map(\.host)).count == Self.cases.count)
    }

    /// Request-level decisions when a host resolves to a given address. With
    /// the private-network opt-in only the loopback rebinding rule applies.
    @Test(arguments: [
        ("probe.example", "93.184.216.34", false, "allowed"),
        ("probe.example", "10.0.0.1", false, "restricted"),
        ("probe.example", "127.0.0.1", false, "unexpectedLoopback"),
        ("probe.example", "::ffff:127.0.0.1", false, "unexpectedLoopback"),
        ("probe.example", "64:ff9b::7f00:1", false, "restricted"),
        ("probe.example", "2002:7f00:1::1", false, "restricted"),
        ("probe.example", "64:ff9b::a00:1", false, "restricted"),
        ("probe.example", "127.0.0.1", true, "unexpectedLoopback"),
        ("probe.example", "::7f00:1", true, "unexpectedLoopback"),
        ("probe.example", "64:ff9b::7f00:1", true, "allowed"),
        ("probe.example", "10.0.0.1", true, "allowed"),
        ("localhost", "127.0.0.1", true, "allowed"),
        ("localhost", "::1", true, "allowed"),
        ("localhost", "93.184.216.34", true, "unexpectedLoopback"),
        ("localhost", "64:ff9b::7f00:1", true, "unexpectedLoopback"),
        ("localhost", "0:0:0:0:0:0:0:1", true, "unexpectedLoopback"),
    ])
    func requestDecisionsAreStable(host: String, address: String, allowsPrivateNetwork: Bool, expected: String) {
        let environment = allowsPrivateNetwork ? ["ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK": "1"] : [:]
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: environment),
            resolver: StaticWebHostResolver(addressesByHost: [host: [address]])
        )
        let decision: String
        do {
            try policy.validateRequestURL("https://\(host)/")
            decision = "allowed"
        } catch let error as WebURLPolicyError {
            if case .restrictedHost = error { decision = "restricted" } else { decision = "url:\(error)" }
        } catch let error as WebNetworkGuardError {
            if case .unexpectedResolvedLoopback = error { decision = "unexpectedLoopback" } else { decision = "guard:\(error)" }
        } catch {
            decision = "other:\(error)"
        }
        #expect(decision == expected, "\(host) -> \(address)")
    }

    private static func decision(loopback: Bool, _ body: () throws -> Void) -> WebAddressDecision {
        do {
            try body()
            return loopback ? .loopback : .allowed
        } catch let error as WebURLPolicyError {
            guard case .restrictedHost = error else { return .invalid }
            return loopback ? .blockedLoopback : .blocked
        } catch {
            return .invalid
        }
    }
}
