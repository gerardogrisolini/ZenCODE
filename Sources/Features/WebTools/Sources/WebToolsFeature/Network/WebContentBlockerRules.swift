//  Content-blocker rule generation for the WebKit renderer (platform-neutral).

import Foundation

/// Builds the WebKit content rule list that blocks every resource load
/// (subresources, subframes, fetch/XHR, websockets, documents) addressed to a
/// literal non-public destination. The navigation delegate validates main-frame
/// and subframe navigations with DNS resolution, but subresource loads never
/// reach it; this list is the only control point for them.
///
/// The rules match the URL *as serialized by WebKit's WHATWG parser*: IPv4
/// literals in octal, hex, decimal or short form are already canonicalized to
/// dotted-quad and IPv6 literals to their compressed lowercase hex form (so an
/// IPv4-mapped address appears as `[::ffff:7f00:1]`, never as
/// `[::ffff:127.0.0.1]`). Matching is case-insensitive by default.
///
/// WebKit's `url-filter` grammar is a strict subset of regular expressions:
/// no alternation (`|`), no `{n,m}` quantifiers, no `\d`/`\w` classes, no
/// lookarounds, `^` only at the start and `$` only at the end. Every pattern
/// here stays inside that subset; alternatives become separate rules.
///
/// Out of scope: a public host name whose DNS answer points into a private
/// network (DNS rebinding of subresources). Enforcing that would require
/// intercepting every subresource request at the transport level, which
/// WebKit only offers through a CDP/proxy, not through WKWebView APIs.
enum WebContentBlockerRules {
    /// `scheme://[userinfo@]` prefix; the host pattern follows immediately.
    private static let urlPrefix = "^[a-z]+://([^/@]*@)?"
    private static let octet = "[0-9]+"
    /// Follows a complete host: serialized special-scheme URLs always continue
    /// with `/` (path) or `:` (port) after the host.
    private static let hostEnd = "[:/]"

    /// Dotted-quad patterns of the restricted IPv4 ranges (first octet, or
    /// first two octets, fixed), mirroring `WebURLPolicy.isRestrictedIPv4`.
    static let restrictedIPv4Prefixes: [String] = {
        let first = ["0", "10", "127", "22[4-9]", "2[3-5][0-9]"]
        let firstTwo = [
            "100\\.6[4-9]", "100\\.[7-9][0-9]", "100\\.1[01][0-9]", "100\\.12[0-7]",
            "169\\.254",
            "172\\.1[6-9]", "172\\.2[0-9]", "172\\.3[01]",
            "192\\.0", "192\\.168",
            "198\\.1[89]", "198\\.51",
            "203\\.0",
        ]
        return first.map { $0 + "\\." + octet + "\\." + octet + "\\." + octet }
            + firstTwo.map { $0 + "\\." + octet + "\\." + octet }
    }()

    /// The same ranges as the leading 16-bit hex group of an IPv6 literal
    /// (no leading zeros, as WHATWG serializes them), used for IPv4-mapped
    /// (`::ffff:xxxx:xxxx`), IPv4-compatible (`::xxxx:xxxx`) and 6to4
    /// (`2002:xxxx:xxxx::`) embeddings.
    static let restrictedIPv4HexGroups: [String] = [
        "[0-9a-f]", "[0-9a-f][0-9a-f]",          // 0.0.0.0/8
        "a[0-9a-f][0-9a-f]",                     // 10.0.0.0/8
        "64[4-7][0-9a-f]",                       // 100.64.0.0/10
        "7f[0-9a-f][0-9a-f]",                    // 127.0.0.0/8
        "a9fe",                                  // 169.254.0.0/16
        "ac1[0-9a-f]",                           // 172.16.0.0/12
        "c0[0-9a-f][0-9a-f]",                    // 192.0.0.0/16 (includes 192.0.2.0/24)
        "c0a8",                                  // 192.168.0.0/16
        "c61[23]", "c633",                       // 198.18.0.0/15, 198.51.0.0/16
        "cb[0-9a-f][0-9a-f]",                    // 203.0.0.0/16
        "[e-f][0-9a-f][0-9a-f][0-9a-f]",         // 224.0.0.0/3 multicast + reserved
    ]

    /// Full `url-filter` patterns, one blocked destination family each.
    static let blockedURLPatterns: [String] = {
        var hosts: [String] = [
            // RFC 6761 loopback and mDNS names (exact and any subdomain), with
            // or without a trailing dot (fully-qualified form), which
            // `WebURLPolicy.normalizedHost` strips and WebKit preserves.
            "localhost\\.?" + hostEnd,
            "[-a-z0-9.]+\\.localhost\\.?" + hostEnd,
            "local\\.?" + hostEnd,
            "[-a-z0-9.]+\\.local\\.?" + hostEnd,
            // IPv6 unspecified/loopback, plus any single-group compatible
            // form (`::xxxx`, i.e. 0.0.0.0/16).
            "\\[::\\]",
            "\\[::[0-9a-f]+\\]",
            // Unique-local fc00::/7, link-local fe80::/10, site-local
            // fec0::/10, multicast ff00::/8.
            "\\[f[cd][0-9a-f][0-9a-f]:",
            "\\[fe[89a-f][0-9a-f]:",
            "\\[ff[0-9a-f][0-9a-f]:",
            // NAT64 local-use prefix 64:ff9b:1::/48 (the well-known prefix is
            // handled per embedded IPv4 below), discard-only 100::/64.
            "\\[64:ff9b:1:",
            "\\[100::",
            // 2001:db8::/32 documentation, 2001:2::/48 benchmarking,
            // 2001:10::/28 and 2001:20::/28 ORCHID.
            "\\[2001:db8:",
            "\\[2001:2:",
            "\\[2001:1[0-9a-f]:",
            "\\[2001:2[0-9a-f]:",
        ]
        // WebKit serializes every IPv4 literal form as a dotted quad.
        hosts += restrictedIPv4Prefixes.map { $0 + hostEnd }
        for group in restrictedIPv4HexGroups {
            // Mapped `::ffff:hi:lo`, compatible `::hi:lo` and NAT64
            // `64:ff9b::hi:lo` always end the host after the low group; 6to4
            // `2002:hi:lo:...` continues with the site suffix.
            hosts.append("\\[::ffff:" + group + ":[0-9a-f]+\\]")
            hosts.append("\\[::" + group + ":[0-9a-f]+\\]")
            hosts.append("\\[64:ff9b::" + group + ":[0-9a-f]+\\]")
            hosts.append("\\[2002:" + group + ":")
        }
        return hosts.map { urlPrefix + $0 }
    }()

    /// Rules in the JSON shape consumed by `WKContentRuleListStore`.
    static var rules: [[String: Any]] {
        blockedURLPatterns.map { pattern in
            [
                "trigger": ["url-filter": pattern] as [String: Any],
                "action": ["type": "block"] as [String: Any],
            ]
        }
    }

    /// Serialized rule list, deterministic across runs.
    static func encodedRuleList() throws -> String {
        let data = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Offline evaluation of the same patterns with ICU semantics (a superset
    /// of the WebKit grammar), for tests and diagnostics: true when at least
    /// one rule would block `serializedURL`.
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
    /// parser accepts. Kept next to the rules so a test can prevent a future
    /// edit from silently breaking compilation at runtime.
    static func usesSupportedSyntax(_ pattern: String) -> Bool {
        if pattern.contains("|") || pattern.contains("{") || pattern.contains("(?") { return false }
        if pattern.contains("\\d") || pattern.contains("\\w") || pattern.contains("\\s") || pattern.contains("\\b") { return false }
        // `^` is only valid as the first character or as a class negation.
        let outsideClasses = pattern.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        if outsideClasses.dropFirst().contains("^") || outsideClasses.dropLast().contains("$") { return false }
        return pattern.unicodeScalars.allSatisfy(\.isASCII)
    }
}
