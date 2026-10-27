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
        #expect(WebURLPolicy.endsInNumber("abc.de") == false)
        #expect(WebURLPolicy.endsInNumber("example.com") == false)
        #expect(WebURLPolicy.endsInNumber("127.1") == true)
        #expect(WebURLPolicy.endsInNumber("0x7f.1") == true)
        #expect(WebURLPolicy.endsInNumber("1.0x") == true)
        #expect(WebURLPolicy.endsInNumber("example.0x1g") == false)
    }

    @Test
    func alternativeIPv4LiteralFormsAreParsedAndRestricted() throws {
        let policy = WebURLPolicy(environment: [:])

        #expect(WebURLPolicy.parseIPv4Literal("0177.0.0.1") == [127, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("2130706433") == [127, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("0x7f.1") == [127, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("127.1") == [127, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("0x7f000001") == [127, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("10.0.1") == [10, 0, 0, 1])
        #expect(WebURLPolicy.parseIPv4Literal("0xa9.0xfe.1.1") == [169, 254, 1, 1])
        #expect(WebURLPolicy.parseIPv4Literal("1.2.3.4.5") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("256.1") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("1.2.3.256") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("4294967296") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("08.1.1.1") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("+1.1.1.1") == nil)
        #expect(WebURLPolicy.parseIPv4Literal("1.-1.1.1") == nil)

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

@Suite
struct WebBoundedLoaderTests {
    private func makeSession() -> URLSession {
        WebToolsSupport.makeBoundedSession(
            policy: WebNetworkRequestPolicy(
                urlPolicy: WebURLPolicy(environment: [:]),
                resolver: StaticWebHostResolver(addressesByHost: ["public.example": ["93.184.216.34"]])
            ),
            timeout: 5
        )
    }

    private func response(status: Int = 200, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(
            url: URL(string: "https://public.example/a")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        ))
    }

    /// Drives the delegate directly with a never-resumed task, so no bytes
    /// hit the network and the limit logic alone is exercised.
    private func awaitResult(
        of box: WebSingleResumeBox<WebBoundedResponse>
    ) async throws -> WebBoundedResponse {
        try await withCheckedThrowingContinuation { continuation in
            box.attach(continuation)
        }
    }

    @Test
    func bodyIsCutAtTheLimitAndReportedAsTruncated() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 10)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(session, dataTask: task, didReceive: try response(), completionHandler: { disposition.record($0) })
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("0123456".utf8))
        delegate.urlSession(session, dataTask: task, didReceive: Data("789ABCDEF".utf8))
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "0123456789")
        #expect(result.wasTruncated)
        // The cancellation that follows the cut must not disturb the result.
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    /// swift-corelibs-foundation invokes `didCompleteWithError` through the
    /// `URLSessionTaskDelegate` existential. The conformance lives on the
    /// `WebRedirectGuard` base class, so the loader's implementation must be
    /// a real override of a base-class method; a method declared only on the
    /// subclass would be bypassed there and the load would never finish
    /// (Darwin dispatches dynamically and would hide the bug).
    @Test
    func completionIsDeliveredThroughTheTaskDelegateExistential() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(session, dataTask: task, didReceive: try response(), completionHandler: { disposition.record($0) })
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("hello".utf8))
        let taskDelegate: any URLSessionTaskDelegate = delegate
        #if canImport(Darwin)
        taskDelegate.urlSession?(session, task: task, didCompleteWithError: nil)
        #else
        taskDelegate.urlSession(session, task: task, didCompleteWithError: nil)
        #endif
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "hello")
    }

    @Test
    func completeBodyWithinTheLimitIsNotTruncated() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)
        let disposition = ResponseDispositionHook()

        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(headers: ["Content-Length": "5"]),
            completionHandler: { disposition.record($0) }
        )
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("hello".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "hello")
        #expect(!result.wasTruncated)
        #expect(result.expectedContentLength == 5)
    }

    @Test
    func declaredOversizedBodyIsTruncatedNotRefused() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 10)
        let disposition = ResponseDispositionHook()

        // A 2xx page declaring more bytes than the limit must still be allowed
        // and cut at the limit, so ordinary large pages are previewed with a
        // `<truncated: N bytes omitted>` note instead of failing.
        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(headers: ["Content-Length": "5000"]),
            completionHandler: { disposition.record($0) }
        )
        #expect(await disposition.value == .allow)
        delegate.urlSession(session, dataTask: task, didReceive: Data("0123456789ABCDEF".utf8))
        let result = try await awaitResult(of: box)
        #expect(String(decoding: result.data, as: UTF8.self) == "0123456789")
        #expect(result.wasTruncated)
        #expect(result.expectedContentLength == 5000)
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
    }

    @Test
    func blockedRedirectIsReportedWithItsPolicyReason() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let delegate = try #require(session.delegate as? WebBoundedLoaderDelegate)
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)
        let box = delegate.register(task: task, limit: 100)

        let redirect = RedirectHookResult()
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: try response(status: 302, headers: ["Location": "http://127.0.0.1:9000/secret"]),
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9000/secret")!),
            completionHandler: { redirect.complete(with: $0) }
        )
        #expect(await redirect.value == nil)
        // URLSession now delivers the 3xx itself and completes without error.
        let disposition = ResponseDispositionHook()
        delegate.urlSession(
            session,
            dataTask: task,
            didReceive: try response(status: 302, headers: ["Location": "http://127.0.0.1:9000/secret"]),
            completionHandler: { disposition.record($0) }
        )
        _ = await disposition.value
        delegate.urlSession(session, task: task, didCompleteWithError: nil)
        do {
            _ = try await awaitResult(of: box)
            Issue.record("a blocked redirect must fail the load")
        } catch let error as WebNetworkGuardError {
            guard case let .blockedRedirect(url, underlying) = error else {
                Issue.record("unexpected guard error \(error)")
                return
            }
            #expect(url == "http://127.0.0.1:9000/secret")
            #expect(underlying.contains("127.0.0.1"))
        }
    }

    @Test
    func redirectChainsAreCapped() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: ["public.example": ["93.184.216.34"]])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URL(string: "https://public.example/a")!)

        for hop in 1...(WebRedirectGuard.maximumRedirects + 1) {
            let hook = RedirectHookResult()
            guardDelegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: try response(status: 302, headers: ["Location": "https://public.example/\(hop)"]),
                newRequest: URLRequest(url: URL(string: "https://public.example/\(hop)")!),
                completionHandler: { hook.complete(with: $0) }
            )
            let followed = await hook.value
            if hop <= WebRedirectGuard.maximumRedirects {
                #expect(followed != nil, "hop \(hop) should be followed")
                #expect(guardDelegate.blockedRedirectError(for: task) == nil)
            } else {
                #expect(followed == nil, "hop \(hop) should be refused")
                #expect(guardDelegate.blockedRedirectError(for: task) is WebNetworkGuardError)
            }
        }
    }

    @Test
    func singleResumeBoxIgnoresLaterResults() async throws {
        let box = WebSingleResumeBox<Int>()
        box.resume(returning: 1)
        box.resume(returning: 2)
        let first: Int = try await withCheckedThrowingContinuation { box.attach($0) }
        #expect(first == 1)
        box.resume(throwing: CancellationError()) // ignored: already resumed
    }
}

/// Captures the disposition passed to a `didReceive response` hook.
private final class ResponseDispositionHook: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLSession.ResponseDisposition, Never>?
    private var stored: URLSession.ResponseDisposition?

    func record(_ disposition: URLSession.ResponseDisposition) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: disposition)
            return
        }
        stored = disposition
        lock.unlock()
    }

    var value: URLSession.ResponseDisposition {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let stored {
                    self.stored = nil
                    lock.unlock()
                    continuation.resume(returning: stored)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}

@Suite
struct WebRedirectGuardTests {
    @Test
    func redirectGuardAllowsPublicRedirectAndRejectsPrivateRedirect() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [
                "public.example": ["93.184.216.34"],
                "internal.example": ["10.0.0.1"],
            ])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let allowed = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://public.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://public.example/b")!),
            completionHandler: { allowed.complete(with: $0) }
        )
        let allowedRequest = await allowed.value
        #expect(allowedRequest?.url?.absoluteString == "https://public.example/b")
        task.cancel()

        let blockedTask = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)
        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: blockedTask,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://internal.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://internal.example/b")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        blockedTask.cancel()
    }

    @Test
    func redirectGuardRejectsRedirectToLoopbackLiteral() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [:])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 301,
                httpVersion: nil,
                headerFields: ["Location": "http://127.0.0.1:9000/secret"]
            )!,
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9000/secret")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        task.cancel()
    }
}

/// Turns the completion-based redirect hook into a single awaitable value.
private final class RedirectHookResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLRequest?, Never>?
    private var result: Result<URLRequest?, Never>?

    func complete(with request: URLRequest?) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: request)
            return
        }
        result = .success(request)
        lock.unlock()
    }

    var value: URLRequest? {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
                lock.lock()
                if let result {
                    self.result = nil
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}

@Suite
struct WebSearchParsingTests {
    private let sampleHTML = """
    <div class="result results_links">
      <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath%3Fq%3D100%2525%26x%3D1&amp;rut=abc">Example &amp; <b>Friends</b></a>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpath">Snippet &lt;one&gt; &#8211; &#x2014; &nbsp; done</a>
    </div>
    <div class="result results_links">
      <a class="result__a" href="https://docs.example.org/page">Docs</a>
      <div class="result__snippet">Second</div>
    </div>
    <div class="result results_links">
      <a class="result__a" href="http://127.0.0.1:8080/admin">Private</a>
    </div>
    <div class="result results_links">
      <a class="result__a" href="javascript:alert(1)">Script</a>
    </div>
    <div class="result results_links">
      <a class="result__a" href="https://evil.example/?u=duckduckgo.com">Not a redirector</a>
    </div>
    """

    @Test
    func redirectorTargetsAreDecodedExactlyOnce() throws {
        let results = WebToolsSupport.parseDuckDuckGoHTMLResults(sampleHTML, limit: 10, domains: [])
        let first = try #require(results.first)
        // `%2525` must become `%25`, not `%`: the query value is already
        // percent-decoded once by URLComponents.
        #expect(first.url == "https://example.com/path?q=100%25&x=1")
        #expect(first.title == "Example & Friends")
        #expect(first.snippet == "Snippet <one> – — done")
        #expect(results.map(\.url).contains("https://docs.example.org/page"))
        #expect(results.map(\.url).contains("https://evil.example/?u=duckduckgo.com"))
        #expect(results.count == 4)
        let direct = try #require(WebToolsSupport.resolvedSearchResultURL(from: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2F%3Fx%3D1%252B1"))
        #expect(direct.absoluteString == "https://a.example/?x=1%2B1")
    }

    @Test
    func domainFilterMatchesHostAndSubdomainsOnly() {
        let docsOnly = WebToolsSupport.parseDuckDuckGoHTMLResults(sampleHTML, limit: 10, domains: ["example.org"])
        #expect(docsOnly.map(\.url) == ["https://docs.example.org/page"])
        let exact = WebToolsSupport.parseDuckDuckGoHTMLResults(sampleHTML, limit: 10, domains: ["ample.com"])
        #expect(exact.isEmpty)
        #expect(WebToolsSupport.normalizedDomains(from: [" Example.COM. ", "", "https://Docs.Example.org/x", "."]) == ["example.com", "docs.example.org"])
    }

    @Test
    func limitIsHonoured() {
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults(sampleHTML, limit: 1, domains: []).count == 1)
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults("", limit: 5, domains: []).isEmpty)
        #expect(WebToolsSupport.parseDuckDuckGoHTMLResults("<a class=\"result__a\" href=\"https://x.example\">", limit: 5, domains: []).isEmpty)
    }

    @Test
    func entityDecodingIsSinglePassAndDeterministic() {
        #expect(WebToolsSupport.decodeHTMLEntities("&amp;lt;") == "&lt;")
        #expect(WebToolsSupport.decodeHTMLEntities("&amp;amp;") == "&amp;")
        #expect(WebToolsSupport.decodeHTMLEntities("a &lt; b &gt; c &quot;d&quot; &#39;e&#39; &apos;f&apos;") == "a < b > c \"d\" 'e' 'f'")
        #expect(WebToolsSupport.decodeHTMLEntities("&#x1F600; &#128512;") == "😀 😀")
        #expect(WebToolsSupport.decodeHTMLEntities("&unknown; &#0; &#xD800; &") == "&unknown; &#0; &#xD800; &")
        #expect(WebToolsSupport.decodeHTMLEntities("plain") == "plain")
    }

    @Test
    func entityDecodingUsesThePageConverterTable() {
        // Same decoder as the page converter: the full Latin-1/Greek/punctuation names...
        #expect(WebToolsSupport.decodeHTMLEntities("caf&eacute; &hellip; &alpha; &#65 &#x41;") == "café … α A A")
        // ...while references that are not meaningful text stay as written.
        #expect(WebToolsSupport.decodeHTMLEntities("&#1; &#127; &#x110000; &#xDFFF; &#9;") == "&#1; &#127; &#x110000; &#xDFFF; \t")
        #expect(WebHTMLEntities.decode("&#0; &#1;") == "\u{FFFD} ")
    }
}

@Suite
struct WebContentBlockerRulesTests {
    @Test
    func rulesUseOnlyTheSupportedURLFilterGrammar() throws {
        #expect(!WebContentBlockerRules.blockedURLPatterns.isEmpty)
        for pattern in WebContentBlockerRules.blockedURLPatterns {
            #expect(WebContentBlockerRules.usesSupportedSyntax(pattern), "unsupported syntax in \(pattern)")
            #expect(throws: Never.self) { try NSRegularExpression(pattern: pattern, options: []) }
        }
        let encoded = try WebContentBlockerRules.encodedRuleList()
        let decoded = try #require(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]])
        #expect(decoded.count == WebContentBlockerRules.blockedURLPatterns.count)
        for rule in decoded {
            #expect((rule["action"] as? [String: Any])?["type"] as? String == "block")
            #expect(((rule["trigger"] as? [String: Any])?["url-filter"] as? String)?.isEmpty == false)
        }
        #expect(try WebContentBlockerRules.encodedRuleList() == encoded)
    }

    @Test
    func blocksLiteralNonPublicDestinations() {
        let blocked = [
            "http://localhost/x", "http://localhost:8080/", "https://api.localhost/x", "http://printer.local/",
            "http://localhost./", "http://api.localhost./", "http://printer.local./",
            "http://127.0.0.1/", "http://127.1.2.3:9000/a", "http://10.1.2.3/", "http://0.0.0.0/",
            "http://192.168.0.1/", "http://169.254.169.254/latest/meta-data", "http://172.16.0.1/", "http://172.31.255.255/",
            "http://100.64.0.1/", "http://100.127.1.1/", "http://224.0.0.1/", "http://255.255.255.255/",
            "http://192.0.2.1/", "http://198.18.0.1/", "http://198.51.100.1/", "http://203.0.113.1/",
            "http://[::1]/", "http://[::]/", "http://[::1]:8080/", "http://[::ffff:7f00:1]/", "http://[::ffff:a00:1]/",
            "http://[::ffff:c0a8:1]/", "http://[::ffff:a9fe:a9fe]/", "http://[::ffff:ac10:1]/", "http://[::ffff:6440:1]/",
            "http://[::7f00:1]/", "http://[2002:7f00:1::1]/", "http://[2002:c0a8:1::]/",
            "http://[fd00::1]/", "http://[fc00::1]/", "http://[fe80::1]/", "http://[fec0::1]/", "http://[ff02::1]/",
            "http://[64:ff9b::7f00:1]/", "http://[100::1]/", "http://[2001:db8::1]/", "http://[2001:2::1]/",
            "http://[2001:10::1]/", "http://[2001:2f::1]/",
            "ws://127.0.0.1:1234/", "https://user@127.0.0.1/", "HTTP://LOCALHOST/",
        ]
        for url in blocked {
            #expect(WebContentBlockerRules.blocks(url), "\(url) should be blocked")
        }
    }

    @Test
    func doesNotBlockPublicDestinations() {
        let allowed = [
            "https://example.com/", "https://localhost.example.com/", "https://mylocal.example/", "https://notlocalhost/",
            "http://93.184.216.34/", "http://8.8.8.8/", "http://172.32.0.1/", "http://172.15.0.1/", "http://100.63.0.1/",
            "http://100.128.0.1/", "http://223.255.255.255/", "http://192.169.0.1/", "http://198.17.0.1/", "http://198.52.0.1/",
            "http://1270.0.0.1/", "http://11.0.0.1/", "http://203.1.0.1/",
            "http://[2606:2800:220:1:248:1893:25c8:1946]/", "http://[2001:4860:4860::8888]/", "http://[2002:5d27:7ed2::1]/",
            "http://[::ffff:5d27:7ed2]/", "http://[64:ff9b::5d27:7ed2]/", "http://[2001:200::1]/", "http://[2001:30::1]/",
            "http://[fb00::1]/", "http://[fe00::1]/", "http://[101::1]/",
            "https://example.com/?next=http://127.0.0.1/", "https://example.com/127.0.0.1/",
        ]
        for url in allowed {
            #expect(!WebContentBlockerRules.blocks(url), "\(url) should not be blocked")
        }
    }

    @Test
    func rulesAgreeWithTheOfflineURLPolicyOnLiteralHosts() throws {
        let policy = WebURLPolicy(environment: [:])
        let literals = [
            "127.0.0.1", "10.0.0.1", "192.168.1.1", "169.254.169.254", "172.16.0.5", "100.64.0.1", "224.0.0.1",
            "[::1]", "[fe80::1]", "[fd00::1]", "[ff02::1]", "[::ffff:a00:1]", "[64:ff9b::7f00:1]",
            "93.184.216.34", "[2606:2800:220:1:248:1893:25c8:1946]", "[2001:4860:4860::8888]", "8.8.8.8",
        ]
        for host in literals {
            let url = "http://\(host)/"
            let policyRejects: Bool
            do {
                _ = try policy.validate(url)
                policyRejects = false
            } catch {
                policyRejects = true
            }
            #expect(WebContentBlockerRules.blocks(url) == policyRejects, "\(url): rules and policy disagree")
        }
    }
}

#if canImport(WebKit)
@Suite
struct WebKitNavigationDecisionTests {
    let policy = WebNetworkRequestPolicy(
        urlPolicy: WebURLPolicy(environment: [:]),
        resolver: StaticWebHostResolver(addressesByHost: [
            "public.example": ["93.184.216.34"],
            "internal.example": ["10.0.0.1"],
        ])
    )

    @Test
    func mainFrameRefusalCarriesThePolicyError() async {
        let decision = await WebKitPageRenderer.decide(url: "https://internal.example/", isMainFrame: true, policy: policy)
        guard case let .cancelMainFrame(error) = decision else {
            Issue.record("expected a main-frame cancellation, got \(decision)")
            return
        }
        #expect(error is WebURLPolicyError)
    }

    @Test
    func subframeRefusalOnlyCancelsTheFrame() async {
        let literal = await WebKitPageRenderer.decide(url: "http://127.0.0.1:9000/", isMainFrame: false, policy: policy)
        guard case .cancelSubframe = literal else {
            Issue.record("expected a subframe cancellation, got \(literal)")
            return
        }
        let rebound = await WebKitPageRenderer.decide(url: "https://internal.example/", isMainFrame: false, policy: policy)
        guard case .cancelSubframe = rebound else {
            Issue.record("expected a subframe cancellation, got \(rebound)")
            return
        }
        let unresolvable = await WebKitPageRenderer.decide(url: "https://nowhere.example/", isMainFrame: false, policy: policy)
        #expect(!unresolvable.isAllowed)
    }

    @Test
    func publicNavigationsAreAllowedInEveryFrame() async {
        #expect(await WebKitPageRenderer.decide(url: "https://public.example/a", isMainFrame: true, policy: policy).isAllowed)
        #expect(await WebKitPageRenderer.decide(url: "https://public.example/frame", isMainFrame: false, policy: policy).isAllowed)
        // Frames without a network destination are allowed; the main frame
        // never is, because it can only be an http(s) document.
        #expect(await WebKitPageRenderer.decide(url: "about:blank", isMainFrame: false, policy: policy).isAllowed)
        #expect(await WebKitPageRenderer.decide(url: "about:srcdoc", isMainFrame: false, policy: policy).isAllowed)
        #expect(!(await WebKitPageRenderer.decide(url: "about:blank", isMainFrame: true, policy: policy).isAllowed))
        #expect(!(await WebKitPageRenderer.decide(url: "file:///etc/hosts", isMainFrame: false, policy: policy).isAllowed))
        #expect(!(await WebKitPageRenderer.decide(url: "ftp://public.example/", isMainFrame: false, policy: policy).isAllowed))
    }
}
#endif
