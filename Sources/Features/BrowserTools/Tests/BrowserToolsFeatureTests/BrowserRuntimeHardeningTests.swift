import Foundation
@testable import BrowserToolsFeature
import Testing

/// Regression coverage for hostile or malformed input reaching the Browser
/// runtime: URL policy edge cases, CDP numeric payloads, dead-session
/// behaviour, and the Chrome HTTP target listing.
@Suite
struct BrowserRuntimeHardeningTests {
    @Test
    func urlPolicyFailsClosedOnUnparseableIPv6LiteralsAndNumericHosts() {
        let policy = BrowserURLPolicy(environment: [:])

        // A zone-scoped link-local literal cannot be parsed by inet_pton and
        // must be refused rather than silently treated as a public host.
        #expect(throws: BrowserURLPolicyError.self) {
            try policy.validate("http://[fe80::1%25en0]:8080/")
        }
        // Alternative IPv4 literal spellings Chrome resolves to loopback or
        // private space.
        #expect(throws: BrowserURLPolicyError.restrictedHost("0x7f.1")) {
            try policy.validate("http://0x7f.1/")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("2130706433")) {
            try policy.validate("http://2130706433/")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("127.1")) {
            try policy.validate("http://127.1/")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("0X7F000001")) {
            try policy.validate("http://0X7F000001/")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("example.123")) {
            try policy.validate("https://example.123/")
        }
    }

    @Test
    func urlPolicyKeepsHexLookingHostnamesSubjectToResolution() throws {
        // Hostnames made only of hexadecimal letters are ordinary DNS names,
        // not numeric literals, and must not be rejected offline.
        let policy = BrowserURLPolicy(environment: [:])
        #expect(try policy.validate("https://adac.de/").host == "adac.de")
        #expect(try policy.validate("https://abc.de/").host == "abc.de")
        #expect(try policy.validate("https://cafe.example/").host == "cafe.example")
    }

    @Test
    func networkRequestPolicyFailsClosedOnEmptyResolverAnswer() {
        let policy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: StaticBrowserHostResolver(addressesByHost: ["empty.example": []])
        )
        #expect(throws: BrowserNetworkGuardError.self) {
            try policy.validateRequestURL("https://empty.example/app")
        }
    }

    @Test
    func offloadedRequestPolicyMatchesSynchronousDecisions() async throws {
        let resolver = StaticBrowserHostResolver(addressesByHost: [
            "public.example": ["10.0.0.1"],
            "rebound.example": ["127.0.0.1"],
            "safe.example": ["93.184.216.34"],
            "localhost": ["127.0.0.1", "::1"],
        ])
        let policy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: resolver
        )

        try await policy.validateRequestURLOffloaded("https://safe.example/app")
        try await policy.validateRequestURLOffloaded("data:text/plain,hello")
        await #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try await policy.validateRequestURLOffloaded("https://public.example/app")
        }
        await #expect(throws: BrowserNetworkGuardError.self) {
            try await policy.validateRequestURLOffloaded("https://rebound.example/app")
        }
        await #expect(throws: BrowserNetworkGuardError.self) {
            try await policy.validateRequestURLOffloaded("wss://localhost:3000/hmr")
        }
        await #expect(throws: BrowserNetworkGuardError.self) {
            try await policy.validateRequestURLOffloaded("file:///etc/hosts")
        }

        let localDevelopmentPolicy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: resolver,
            allowsLoopback: true
        )
        try await localDevelopmentPolicy.validateRequestURLOffloaded("wss://localhost:3000/hmr")
    }

    @Test
    func numericCDPValuesNeverTrapOnHostileDoubles() {
        #expect(BrowserNetworkValue.integer(Double.nan) == nil)
        #expect(BrowserNetworkValue.integer(Double.infinity) == nil)
        #expect(BrowserNetworkValue.integer(1e300) == nil)
        #expect(BrowserNetworkValue.integer(Double(Int.max)) == nil)
        #expect(BrowserNetworkValue.integer(42.9) == 42)
        #expect(BrowserNetworkValue.integer(-42.9) == -42)
        #expect(BrowserNetworkValue.integer(NSNumber(value: 1e300)) == nil)
        #expect(BrowserNetworkValue.integer(7) == 7)

        #expect(BrowserNetworkValue.nonNegativeInt64(Double.nan) == nil)
        #expect(BrowserNetworkValue.nonNegativeInt64(1e300) == nil)
        #expect(BrowserNetworkValue.nonNegativeInt64(-5.0) == 0)
        #expect(BrowserNetworkValue.nonNegativeInt64(NSNumber(value: Double.infinity)) == nil)
        #expect(BrowserNetworkValue.nonNegativeInt64(12.0) == 12)
    }

    @Test
    func integralNSNumbersAreReadExactlyAndFloatingOnesStayGuarded() {
        // Int64.max - 1 is not representable as a Double; a Double round trip
        // would silently change it (or trap on conversion).
        let large = NSNumber(value: Int64.max - 1)
        #expect(BrowserNetworkValue.nonNegativeInt64(large) == Int64.max - 1)
        #expect(BrowserNetworkValue.integer(large) == Int(Int64.max - 1))
        #expect(BrowserNetworkValue.integer(NSNumber(value: 42)) == 42)
        #expect(BrowserNetworkValue.integer(NSNumber(value: -7)) == -7)
        #expect(BrowserNetworkValue.nonNegativeInt64(NSNumber(value: -7)) == 0)
        #expect(BrowserNetworkValue.nonNegativeInt64(NSNumber(value: UInt64.max)) == nil)

        #expect(BrowserNetworkValue.integer(NSNumber(value: Double.nan)) == nil)
        #expect(BrowserNetworkValue.nonNegativeInt64(NSNumber(value: Double.nan)) == nil)
        #expect(BrowserNetworkValue.integer(NSNumber(value: 42.9)) == 42)
        #expect(BrowserNetworkValue.nonNegativeInt64(NSNumber(value: 12.5)) == 12)
    }

    @Test
    func accessibilityAndInspectionParsersSurviveHostileNumericIdentifiers() throws {
        let snapshot = try BrowserAccessibilitySnapshot.parse([
            "result": [
                "nodes": [
                    [
                        "nodeId": "1",
                        "backendDOMNodeId": 1e300,
                        "ignored": false,
                        "role": ["value": "button"],
                    ],
                    [
                        "nodeId": "2",
                        "backendDOMNodeId": 7,
                        "ignored": false,
                        "role": ["value": "link"],
                    ],
                ],
            ],
        ], interactiveOnly: false)
        #expect(snapshot.nodes.map(\.ref) == ["ax-1", "ax-2"])
        #expect(snapshot.targets["ax-1"] == nil)
        #expect(snapshot.targets["ax-2"]?.backendDOMNodeID == 7)

        #expect(throws: CDPError.self) {
            try BrowserDOMInspection.parseFrontendNodeID(["result": ["nodeIds": [Double.nan]]])
        }
        #expect(throws: CDPError.self) {
            try BrowserDOMInspection.parseDOMNode([
                "result": ["node": ["nodeId": 1e300, "localName": "div"]],
            ])
        }

        let metrics = try BrowserPerformanceSnapshot.parse([
            "result": [
                "metrics": [
                    ["name": "Nodes", "value": Double.nan],
                    ["name": "Documents", "value": 1],
                ],
            ],
        ])
        #expect(metrics.map(\.name) == ["Documents"])
    }

    @Test
    func disconnectedSessionFailsCommandsImmediately() async {
        let session = CDPSession(webSocketURL: URL(string: "ws://127.0.0.1:9/devtools/page/test")!)
        #expect(!session.isTerminated)
        session.disconnect()
        #expect(session.isTerminated)

        let start = ContinuousClock.now
        await #expect(throws: CDPError.self) {
            _ = try await session.send(method: "Page.enable")
        }
        // The default command timeout is 30 s; a dead transport must not wait.
        #expect(start.duration(to: .now) < .seconds(5))

        // Poll loops stop retrying on a dead session instead of exhausting
        // their multi-second budgets.
        await #expect(throws: CDPError.self) {
            try await session.waitReady()
        }
        await #expect(throws: CDPError.self) {
            try await session.waitNavigatedReady()
        }
        let waitResult = await #expect(throws: CDPError.self) {
            try await session.waitForPageCondition(condition: .ready, literal: nil, timeoutSeconds: 30)
        }
        #expect(waitResult != nil)
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test
    func chromeTargetTitlesAreUnescapedLikeDocumentTitle() {
        #expect(ChromeBrowserManager.unescapedTargetTitle("Tom &amp; Jerry &lt;3 &quot;quoted&quot; it&#39;s") == "Tom & Jerry <3 \"quoted\" it's")
        #expect(ChromeBrowserManager.unescapedTargetTitle("Plain title") == "Plain title")
        // Double escaping is undone exactly once, matching Chrome's one pass.
        #expect(ChromeBrowserManager.unescapedTargetTitle("&amp;lt;") == "&lt;")
    }
}
