//
//  WebContentBlockerRulesTests.swift
//  ZenCODE
//
//  Search parsing and WebKit content blocker rule suites of the web tools,
//  plus the WebKit navigation decision suite.
//

import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import WebToolsFeature
import Testing

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

/// Offline helpers to check the production rule list without WebKit.
extension WebContentBlockerRules {
    /// Offline evaluation of the same patterns with ICU semantics (a superset
    /// of the WebKit grammar): true when at least one rule would block
    /// `serializedURL`.
    static func blocks(_ serializedURL: String) -> Bool {
        let range = NSRange(serializedURL.startIndex..<serializedURL.endIndex, in: serializedURL)
        return blockedURLPatterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return false
            }
            return regex.firstMatch(in: serializedURL, options: [], range: range) != nil
        }
    }

    /// True when a pattern uses only the constructs WebKit's `url-filter`
    /// parser accepts, so a future edit cannot silently break the compilation
    /// of the rule list at runtime.
    static func usesSupportedSyntax(_ pattern: String) -> Bool {
        if pattern.contains("|") || pattern.contains("{") || pattern.contains("(?") { return false }
        if pattern.contains("\\d") || pattern.contains("\\w") || pattern.contains("\\s") || pattern.contains("\\b") { return false }
        // `^` is only valid as the first character or as a class negation.
        let outsideClasses = pattern.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        if outsideClasses.dropFirst().contains("^") || outsideClasses.dropLast().contains("$") { return false }
        return pattern.unicodeScalars.allSatisfy(\.isASCII)
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
extension WebKitPageRenderer.NavigationDecision {
    var isAllowed: Bool {
        if case .allow = self { return true }
        return false
    }
}

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
