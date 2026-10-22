import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WebSearchResult {
    let title: String
    let url: String
    let snippet: String
}

extension WebToolsSupport {
    static func normalizedDomains(from domains: [String]) -> [String] {
        domains
            .map { domain -> String in
                var value = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                // Tolerate `https://example.com/path` style entries: only the host matters.
                if let schemeRange = value.range(of: "://") {
                    value = String(value[schemeRange.upperBound...])
                }
                if let slash = value.firstIndex(of: "/") {
                    value = String(value[..<slash])
                }
                return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            }
            .filter { !$0.isEmpty }
    }

    static func parseDuckDuckGoHTMLResults(_ html: String, limit: Int, domains: [String]) -> [WebSearchResult] {
        let anchorPattern = #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let snippetPattern = #"<(?:a|div)[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</(?:a|div)>"#

        guard let anchorRegex = try? NSRegularExpression(
            pattern: anchorPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return []
        }
        let snippetRegex = try? NSRegularExpression(
            pattern: snippetPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = anchorRegex.matches(in: html, options: [], range: nsRange)
        var results: [WebSearchResult] = []
        for (index, match) in matches.enumerated() {
            guard let hrefRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let resultURL = resolvedSearchResultURL(from: String(html[hrefRange])),
                  isAllowedSearchResultURL(resultURL, domains: domains) else {
                continue
            }

            let title = normalizeText(stripHTML(String(html[titleRange])))
            guard !title.isEmpty else { continue }

            let lowerBound = match.range.location + match.range.length
            let upperBound = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.location + nsRange.length
            let searchRange = NSRange(location: lowerBound, length: max(upperBound - lowerBound, 0))
            let snippet: String
            if let snippetRegex,
               let snippetMatch = snippetRegex.firstMatch(in: html, options: [], range: searchRange),
               let snippetRange = Range(snippetMatch.range(at: 1), in: html) {
                snippet = normalizeText(stripHTML(String(html[snippetRange])))
            } else {
                snippet = ""
            }

            results.append(
                WebSearchResult(title: title, url: resultURL.absoluteString, snippet: snippet)
            )
            if results.count >= limit {
                break
            }
        }
        return results
    }

    static func resolvedSearchResultURL(from rawHref: String) -> URL? {
        let href = decodeHTMLEntities(rawHref)
        let normalizedHref = href.hasPrefix("//") ? "https:\(href)" : href
        guard let url = URL(string: normalizedHref) else { return nil }
        if let host = url.host?.lowercased(),
           host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com"),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           // `queryItems` already percent-decodes the value once; decoding
           // again would corrupt targets that legitimately contain `%xx`.
           let decodedTarget = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let targetURL = URL(string: decodedTarget) {
            return targetURL
        }
        return url
    }

    private static func isAllowedSearchResultURL(_ url: URL, domains: [String]) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return false
        }
        guard !domains.isEmpty else { return true }
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static func stripHTML(_ text: String) -> String {
        replacePattern(text, pattern: #"<[^>]+>"#, with: " ")
    }

    private static func normalizeText(_ text: String) -> String {
        decodeHTMLEntities(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacePattern(_ text: String, pattern: String, with replacement: String) -> String {
        (try? NSRegularExpression(pattern: pattern, options: []))?
            .stringByReplacingMatches(
                in: text,
                options: [],
                range: NSRange(text.startIndex..<text.endIndex, in: text),
                withTemplate: replacement
            ) ?? text
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "hellip": "\u{2026}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "lsquo": "\u{2018}", "rsquo": "\u{2019}", "copy": "\u{00A9}",
        "reg": "\u{00AE}", "trade": "\u{2122}", "euro": "\u{20AC}", "middot": "\u{00B7}", "bull": "\u{2022}",
    ]

    /// Single-pass entity decoder: every `&name;`, `&#NNN;` and `&#xHH;` is
    /// replaced exactly once from the original text, so `&amp;lt;` decodes to
    /// `&lt;` deterministically rather than depending on replacement order.
    static func decodeHTMLEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"&(#[xX][0-9A-Fa-f]{1,6}|#[0-9]{1,7}|[A-Za-z][A-Za-z0-9]{1,31});"#) else {
            return text
        }
        var decoded = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            guard let matchRange = Range(match.range, in: text), let bodyRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            decoded += text[cursor..<matchRange.lowerBound]
            let body = text[bodyRange]
            if let replacement = decodedEntityBody(body) {
                decoded += replacement
            } else {
                decoded += text[matchRange]
            }
            cursor = matchRange.upperBound
        }
        decoded += text[cursor...]
        return decoded
    }

    private static func decodedEntityBody(_ body: Substring) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            // Control characters and surrogates are not meaningful text.
            guard let value, value >= 0x20 || value == 0x09 || value == 0x0A, let scalar = Unicode.Scalar(value) else {
                return nil
            }
            return String(Character(scalar))
        }
        return namedEntities[String(body)]
    }
}
