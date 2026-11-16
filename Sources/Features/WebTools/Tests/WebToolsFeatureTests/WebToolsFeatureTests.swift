import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

/// Deterministic resolver used to exercise the network request policy without
/// touching the real DNS stack.
struct StaticWebHostResolver: WebHostResolving {
    let addressesByHost: [String: [String]]

    func resolve(host: String) throws -> [String] {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let addresses = addressesByHost[normalized] ?? addressesByHost[host] else {
            throw WebNetworkGuardError.unresolvedHost(host)
        }
        return addresses
    }
}

@Suite
struct WebURLPolicyTests {
    @Test
    func allowsPublicDestinations() throws {
        let policy = WebURLPolicy(environment: [:])

        #expect(try policy.validate("https://example.com/path?q=1").host == "example.com")
        #expect(try policy.validate("http://93.184.216.34/").host == "93.184.216.34")
        #expect(try policy.validate("https://[2606:2800:220:1:248:1893:25c8:1946]/").host != nil)
    }

    @Test
    func rejectsNonPublicDestinations() {
        let policy = WebURLPolicy(environment: [:])

        #expect(throws: WebURLPolicyError.restrictedHost("localhost")) {
            try policy.validate("http://localhost:8080")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://127.0.0.1:3000")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::1]:8080")
        }
        #expect(throws: WebURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validate("http://10.0.0.1")
        }
        #expect(throws: WebURLPolicyError.restrictedHost("169.254.169.254")) {
            try policy.validate("http://169.254.169.254/latest/meta-data")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://192.168.1.1/admin")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://172.16.0.5")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://100.64.0.1")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("https://service.local")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://0177.0.0.1")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[fe80::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[fd00::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[ff02::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::ffff:a00:1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::]")
        }
        #expect(throws: WebURLPolicyError.credentialsNotAllowed("https://user:secret@example.com")) {
            try policy.validate("https://user:secret@example.com")
        }
        #expect(throws: WebURLPolicyError.unsupportedScheme("file")) {
            try policy.validate("file:///etc/passwd")
        }
    }

    @Test
    func privateNetworkOverrideIsHostControlled() throws {
        let policy = WebURLPolicy(environment: [
            "ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK": "true"
        ])

        #expect(try policy.validate("http://192.168.1.10:8080").host == "192.168.1.10")
        #expect(try policy.validate("https://service.local").host == "service.local")
    }

    @Test
    func allHexHostNamesAreNotMistakenForIPv4Literals() throws {
        let policy = WebURLPolicy(environment: [:])

        // WHATWG "ends in a number": these last labels are neither all
        // digits nor 0x-prefixed, so they are DNS names, not IPv4 candidates.
        #expect(try policy.validate("https://abc.de/").host == "abc.de")
        #expect(try policy.validate("https://cafe.de/").host == "cafe.de")
        #expect(try policy.validate("https://face.be/").host == "face.be")
        #expect(try policy.validate("https://0xdead.beef.example/").host == "0xdead.beef.example")
        #expect(FeatureIPAddress.endsInNumber("abc.de") == false)
        #expect(FeatureIPAddress.endsInNumber("example.com") == false)
        #expect(FeatureIPAddress.endsInNumber("127.1") == true)
        #expect(FeatureIPAddress.endsInNumber("0x7f.1") == true)
        #expect(FeatureIPAddress.endsInNumber("1.0x") == true)
        #expect(FeatureIPAddress.endsInNumber("example.0x1g") == false)
    }

    @Test
    func alternativeIPv4LiteralFormsAreParsedAndRestricted() throws {
        let policy = WebURLPolicy(environment: [:])

        #expect(FeatureIPAddress.parseIPv4Literal("0177.0.0.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("2130706433") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0x7f.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("127.1") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0x7f000001") == [127, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("10.0.1") == [10, 0, 0, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("0xa9.0xfe.1.1") == [169, 254, 1, 1])
        #expect(FeatureIPAddress.parseIPv4Literal("1.2.3.4.5") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("256.1") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("1.2.3.256") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("4294967296") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("08.1.1.1") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("+1.1.1.1") == nil)
        #expect(FeatureIPAddress.parseIPv4Literal("1.-1.1.1") == nil)

        for host in ["2130706433", "0x7f.1", "127.1", "0x7f000001", "10.0.1", "0xa9.0xfe.1.1", "0.0.0.0", "0", "0251.0376.1.1"] {
            #expect(throws: WebURLPolicyError.self, "\(host) should be restricted") {
                try policy.validate("http://\(host)/")
            }
        }
        // Unparsable candidates (too many labels, overflow) fail closed.
        #expect(throws: WebURLPolicyError.self) { try policy.validate("http://1.2.3.4.5/") }
        #expect(throws: WebURLPolicyError.self) { try policy.validate("http://4294967296/") }
        #expect(throws: WebURLPolicyError.self) { try policy.validate("http://example.0x/") }
        // Public addresses in alternative forms remain allowed.
        #expect(try policy.validate("http://1562726098/").host == "1562726098") // 93.39.126.210
        #expect(try policy.validate("http://0x5d.0x27.0x7ed2/").host != nil)
        // A non-final label above 255 is not a valid literal and fails closed.
        #expect(throws: WebURLPolicyError.self) { try policy.validate("http://0x5d27.0x7ed2/") }
        #expect(policy.isLoopbackHost("2130706433"))
        #expect(policy.isLoopbackHost("0x7f.1"))
        #expect(!policy.isLoopbackHost("8.8.8.8"))
    }

    @Test
    func rejectsSpecialIPv6RangesAndUnparsableLiterals() throws {
        let policy = WebURLPolicy(environment: [:])

        let restricted = [
            "[fe80::1%25en0]",
            "[100::1]",
            "[2001:db8::1]",
            "[2001:2::1]",
            "[2001:10::1]",
            "[2001:2f::1]",
            "[2002:7f00:1::1]",
            "[2002:a00:1::1]",
            "[2002:c0a8:101::1]",
            "[64:ff9b::7f00:1]",
            "[64:ff9b::a9fe:a9fe]",
            "[64:ff9b:1::1]",
            "[::7f00:1]",
            "[::ffff:127.0.0.1]",
            "[::ffff:169.254.169.254]",
            "[fec0::1]",
            "[::ffff:0:0]",
        ]
        for host in restricted {
            #expect(throws: WebURLPolicyError.self, "\(host) should be restricted") {
                try policy.validate("http://\(host)/")
            }
        }
        // Zone identifiers are never public, and malformed literals fail closed.
        #expect(throws: WebURLPolicyError.self) { try policy.validateResolvedAddress("fe80::1%en0") }
        #expect(throws: WebURLPolicyError.self) { try policy.validateResolvedAddress("2606:2800:220:1:248:1893:25c8:1946:ffff") }
        #expect(throws: WebURLPolicyError.self) { try policy.validateResolvedAddress("1:2:3") }
        // Public IPv6 in the neighbourhood of the special ranges stays allowed.
        #expect(try policy.validate("http://[2001:4860:4860::8888]/").host != nil)
        #expect(try policy.validate("http://[2002:5d27:7ed2::1]/").host != nil)
        #expect(try policy.validate("http://[64:ff9b::5d27:7ed2]/").host != nil)
        #expect(try policy.validate("http://[2001:200::1]/").host != nil)
        #expect(try policy.validate("http://[2001:30::1]/").host != nil)
    }
}

@Suite
struct WebNetworkRequestPolicyTests {
    let resolver = StaticWebHostResolver(addressesByHost: [
        "public.example": ["93.184.216.34"],
        "mixed.example": ["93.184.216.34", "fd00::1"],
        "rebound.example": ["127.0.0.1"],
        "metadata.example": ["169.254.169.254"],
        "localhost": ["127.0.0.1", "::1"],
        "dualstack.example": ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
    ])

    @Test
    func allowsPublicRequests() throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        try policy.validateRequestURL("https://public.example/app")
        try policy.validateRequestURL("https://dualstack.example/app")
    }

    @Test
    func rejectsNonPublicRequestsFailClosed() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        #expect(throws: WebURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validateRequestURL("http://10.0.0.1/admin")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://localhost:3000/debug")
        }
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("file:///private/file")
        }
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("ftp://example.com/file")
        }
    }

    @Test
    func rejectsResolvedPrivateAddresses() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        // Mixed A/AAAA where any address is restricted fails closed.
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://mixed.example/app")
        }
        // DNS rebinding: a public-looking host that resolves to loopback.
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("https://rebound.example/app")
        }
        // DNS rebinding to the cloud metadata endpoint.
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://metadata.example/latest/meta-data")
        }
    }

    @Test
    func failsClosedWhenHostIsUnresolvable() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [:])
        )

        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("https://unresolvable.example/app")
        }
    }

    @Test
    func failsClosedWhenResolverReturnsNoAddresses() async {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: ["empty.example": []])
        )

        // An empty answer has nothing to validate and must not pass silently.
        for attempt in ["sync", "offloaded"] {
            do {
                if attempt == "sync" {
                    try policy.validateRequestURL("https://empty.example/app")
                } else {
                    try await policy.validateRequestURLOffloaded("https://empty.example/app")
                }
                Issue.record("\(attempt): an empty resolver answer must fail closed")
            } catch let error as WebNetworkGuardError {
                guard case let .noResolvedAddresses(host) = error else {
                    Issue.record("\(attempt): unexpected guard error \(error)")
                    continue
                }
                #expect(host == "empty.example")
            } catch {
                Issue.record("\(attempt): unexpected error \(error)")
            }
        }
    }

    @Test
    func offloadedValidationMirrorsSynchronousDecisions() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        try await policy.validateRequestURLOffloaded("https://public.example/app")
        await #expect(throws: WebNetworkGuardError.self) {
            try await policy.validateRequestURLOffloaded("https://rebound.example/app")
        }
        await #expect(throws: WebURLPolicyError.self) {
            try await policy.validateRequestURLOffloaded("http://127.0.0.1:8080")
        }
    }

    @Test
    func privateNetworkOverrideAppliesToResolvedAddresses() throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [
                "ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK": "1"
            ]),
            resolver: StaticWebHostResolver(addressesByHost: [
                "192.168.1.10": ["192.168.1.10"],
                "mixed.example": ["93.184.216.34", "fd00::1"],
            ])
        )

        try policy.validateRequestURL("http://192.168.1.10:8080")
        try policy.validateRequestURL("https://mixed.example/app")
    }
}

@Suite
struct WebFetchToolPolicyTests {
    func makeContext(_ environment: [String: String] = [:]) -> FeatureContext {
        FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: environment)
    }

    @Test
    func fetchToolRejectsLoopbackBeforeAnyNetworkActivity() async {
        let tool = WebFetchTool()
        let input = WebFetchTool.Input(url: "http://127.0.0.1:8080/admin", maxBytes: nil, timeoutSeconds: nil)

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(input, context: makeContext())
        }
    }

    @Test
    func fetchToolRejectsMetadataEndpointBeforeAnyNetworkActivity() async {
        let tool = WebFetchTool()
        let input = WebFetchTool.Input(
            url: "http://169.254.169.254/latest/meta-data/iam/security-credentials",
            maxBytes: nil,
            timeoutSeconds: nil
        )

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(input, context: makeContext())
        }
    }

    @Test
    func fetchToolRejectsCredentialsAndNonHTTPScheme() async {
        let tool = WebFetchTool()

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(
                WebFetchTool.Input(url: "https://user:secret@example.com", maxBytes: nil, timeoutSeconds: nil),
                context: makeContext()
            )
        }
        await #expect(throws: WebNetworkGuardError.self) {
            _ = try await tool.run(
                WebFetchTool.Input(url: "file:///etc/passwd", maxBytes: nil, timeoutSeconds: nil),
                context: makeContext()
            )
        }
    }

    @Test
    func guardedSessionWiresTheRedirectGuard() {
        let session = WebToolsSupport.makeURLSession(
            policy: WebNetworkRequestPolicy(
                urlPolicy: WebURLPolicy(environment: [:]),
                resolver: StaticWebHostResolver(addressesByHost: [:])
            )
        )
        defer { session.finishTasksAndInvalidate() }

        #expect(session.delegate is WebRedirectGuard)
        #expect(session.delegate is WebBoundedLoaderDelegate)
        #expect(session.configuration.timeoutIntervalForResource == 20)
    }

    @Test
    func markdownTruncationNeverSplitsACharacter() {
        let text = "héllo wörld ✓ done"
        for limit in 1...text.utf8.count {
            let cut = WebFetchTool.truncated(text, toBytes: limit)
            #expect(cut.utf8.count <= limit)
            #expect(text.hasPrefix(cut))
            #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut)
        }
        #expect(WebFetchTool.truncated(text, toBytes: 1_000) == text)
    }
}

@Suite
struct WebBodyDecodingTests {
    @Test
    func decodesUsingDeclaredHeaderCharset() throws {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in ISO-8859-1
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=ISO-8859-1"]
        ))
        #expect(WebToolsSupport.decodeBody(latin1, response: response) == "café")
    }

    @Test
    func decodesUsingMetaCharsetWhenHeaderIsSilent() throws {
        let latin1Body = Data("<html><head><meta charset=\"iso-8859-1\"></head><body>caf".utf8) + Data([0xE9])
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        ))
        let decoded = WebToolsSupport.decodeBody(latin1Body, response: response)
        #expect(decoded.hasSuffix("café"))

        let httpEquiv = Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1252\">".utf8)
        #expect(WebToolsSupport.sniffedHTMLEncoding(in: httpEquiv) == .windowsCP1252)
        #expect(WebToolsSupport.sniffedHTMLEncoding(in: Data("<html><body>plain</body></html>".utf8)) == nil)
    }

    @Test
    func truncatedUTF8IsDecodedLossilyInsteadOfFailing() {
        // "héll": the byte cut falls on a character boundary, so decoding is exact.
        var bytes = Array("héllo".utf8)
        bytes.removeLast()
        // "h" + the first byte of "é": the cut falls inside a multi-byte
        // character, which must become U+FFFD rather than fail the whole body.
        let cutInsideCharacter = Data(Array("hé".utf8).dropLast())
        let decoded = WebToolsSupport.decodeBody(cutInsideCharacter, response: nil)
        #expect(decoded.hasPrefix("h"))
        #expect(decoded.contains("\u{FFFD}"))
        #expect(WebToolsSupport.decodeBody(Data(bytes), response: nil) == "héll")
    }

    @Test
    func unknownCharsetFallsBackToUTF8() throws {
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=x-made-up"]
        ))
        #expect(WebToolsSupport.decodeBody(Data("ok ✓".utf8), response: response) == "ok ✓")
        #expect(WebToolsSupport.encoding(named: "UTF-8") == .utf8)
        #expect(WebToolsSupport.encoding(named: " Windows-1251 ") == .windowsCP1251)
        #expect(WebToolsSupport.encoding(named: "x-made-up") == nil)
    }
}
