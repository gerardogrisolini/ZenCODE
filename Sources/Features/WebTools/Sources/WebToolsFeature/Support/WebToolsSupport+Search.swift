import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct WebSearchResult: Equatable, Sendable {
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

    /// Maximum length of a result snippet, in characters.
    static let maxSnippetCharacters = 400

    /// Parses the DuckDuckGo HTML endpoint (`html.duckduckgo.com/html/`):
    /// `<a class="result__a">` titles with `result__snippet` summaries.
    static func parseDuckDuckGoHTMLResults(_ html: String, limit: Int, domains: [String]) -> [WebSearchResult] {
        parseSearchResults(html, limit: limit, domains: domains, anchorClass: "result__a", snippetClass: "result__snippet")
    }

    /// Parses the DuckDuckGo Lite endpoint (`lite.duckduckgo.com/lite/`):
    /// `<a class='result-link'>` titles (attribute order and quote style
    /// vary) followed by a `<td class='result-snippet'>` summary.
    static func parseDuckDuckGoLiteResults(_ html: String, limit: Int, domains: [String]) -> [WebSearchResult] {
        parseSearchResults(html, limit: limit, domains: domains, anchorClass: "result-link", snippetClass: "result-snippet")
    }

    private static func parseSearchResults(
        _ html: String,
        limit: Int,
        domains: [String],
        anchorClass: String,
        snippetClass: String
    ) -> [WebSearchResult] {
        guard limit > 0 else { return [] }
        let anchorPattern = #"<a\b\#(classLookahead(anchorClass))([^>]*)>(.*?)</a>"#
        let snippetPattern = #"<(a|div|td|span)\b\#(classLookahead(snippetClass))[^>]*>(.*?)</\1>"#

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
            guard let attributesRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let href = htmlAttribute("href", in: String(html[attributesRange])),
                  let resultURL = resolvedSearchResultURL(from: href),
                  isAllowedSearchResultURL(resultURL, domains: domains) else {
                continue
            }

            let title = plainText(fromHTML: String(html[titleRange]))
            guard !title.isEmpty else { continue }

            let lowerBound = match.range.location + match.range.length
            let upperBound = index + 1 < matches.count ? matches[index + 1].range.location : nsRange.location + nsRange.length
            let searchRange = NSRange(location: lowerBound, length: max(upperBound - lowerBound, 0))
            let snippet: String
            if let snippetRegex,
               let snippetMatch = snippetRegex.firstMatch(in: html, options: [], range: searchRange),
               let snippetRange = Range(snippetMatch.range(at: 2), in: html) {
                snippet = cappedSnippet(plainText(fromHTML: String(html[snippetRange])))
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

    /// Lookahead that only succeeds when the opening tag has a `class`
    /// attribute (single- or double-quoted) containing `className` as a whole
    /// token, so `result__a` does not match `result__a_extra`.
    private static func classLookahead(_ className: String) -> String {
        let token = NSRegularExpression.escapedPattern(for: className)
        let boundary = #"(?<![\w-])\#(token)(?![\w-])"#
        return #"(?=[^>]*?\sclass\s*=\s*(?:"[^"]*\#(boundary)[^"]*"|'[^']*\#(boundary)[^']*'))"#
    }

    /// Finds the hidden-field set of the "Next" pagination form, in document
    /// order, for both the HTML endpoint (`<input ... value="Next" />`) and the
    /// Lite endpoint (`<input type="submit" class='navbutton' value="Next Page &gt;">`).
    ///
    /// A form qualifies when it contains a submit input whose decoded label
    /// starts with "next" (case-insensitive); when several qualify the last
    /// one wins (the page repeats it at the bottom). Result pages after the
    /// first also carry a "Previous" form, which is never selected. Values are
    /// entity-decoded. Returns `nil` when there is no next form, which is how
    /// the engine signals the end of the results.
    static func parseDuckDuckGoNextForm(_ html: String) -> [(name: String, value: String)]? {
        guard html.range(of: "<form", options: .caseInsensitive) != nil,
              let formRegex = try? NSRegularExpression(
                  pattern: #"<form\b(?:[^>"']|"[^"]*"|'[^']*')*>(.*?)</form\s*>"#,
                  options: [.caseInsensitive, .dotMatchesLineSeparators]
              ),
              let inputRegex = try? NSRegularExpression(
                  pattern: #"<input\b((?:[^>"']|"[^"]*"|'[^']*')*)>"#,
                  options: [.caseInsensitive]
              ) else {
            return nil
        }

        var nextFields: [(name: String, value: String)]?
        for formMatch in formRegex.matches(in: html, options: [], range: NSRange(html.startIndex..<html.endIndex, in: html)) {
            guard let bodyRange = Range(formMatch.range(at: 1), in: html) else { continue }
            let body = String(html[bodyRange])
            var hasNextButton = false
            var fields: [(name: String, value: String)] = []
            for inputMatch in inputRegex.matches(in: body, options: [], range: NSRange(body.startIndex..<body.endIndex, in: body)) {
                guard let attributesRange = Range(inputMatch.range(at: 1), in: body) else { continue }
                let attributes = String(body[attributesRange])
                let value = decodeHTMLEntities(htmlAttribute("value", in: attributes) ?? "")
                switch htmlAttribute("type", in: attributes)?.lowercased() {
                case "submit":
                    if value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("next") {
                        hasNextButton = true
                    }
                case "hidden":
                    if let name = htmlAttribute("name", in: attributes).map(decodeHTMLEntities), !name.isEmpty {
                        fields.append((name: name, value: value))
                    }
                default:
                    break
                }
            }
            if hasNextButton, !fields.isEmpty {
                nextFields = fields
            }
        }
        return nextFields
    }

    /// Compiled once: `htmlAttribute` runs for every result and form input.
    private static let attributeRegexes: [String: NSRegularExpression] = {
        var regexes: [String: NSRegularExpression] = [:]
        for name in ["href", "name", "type", "value"] {
            regexes[name] = attributeRegex(for: name)
        }
        return regexes
    }()

    private static func attributeRegex(for name: String) -> NSRegularExpression? {
        let pattern = #"(?<![\w:-])\#(NSRegularExpression.escapedPattern(for: name))\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    /// Value of attribute `name` in the text of an opening tag (the part
    /// between the tag name and `>`), for double-quoted, single-quoted and
    /// unquoted values. The value is returned as written (not entity-decoded).
    private static func htmlAttribute(_ name: String, in attributes: String) -> String? {
        guard let regex = attributeRegexes[name] ?? attributeRegex(for: name),
              let match = regex.firstMatch(in: attributes, options: [], range: NSRange(attributes.startIndex..<attributes.endIndex, in: attributes)) else {
            return nil
        }
        for group in 1...3 {
            if let range = Range(match.range(at: group), in: attributes) {
                return String(attributes[range])
            }
        }
        return nil
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
        // Sponsored results point at the engine's own click tracker, not at a page.
        if (host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com")), url.path == "/y.js" {
            return false
        }
        guard !domains.isEmpty else { return true }
        return domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }

    private static let lineBreakTagRegex = try? NSRegularExpression(
        pattern: #"</?(?:br|p|div|li|ul|ol|tr|td|th|table|h[1-6]|hr)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let anyTagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#)

    /// Removes tags. Line-breaking tags become a space so adjacent blocks do
    /// not run together; inline tags (`<b>`, `<i>`, `<span>`, ...) are removed
    /// without a replacement, which keeps `swift<b>-testing</b>` one word and
    /// avoids stray spaces before punctuation.
    private static func stripHTML(_ text: String) -> String {
        let separated = replacing(lineBreakTagRegex, in: text, with: " ")
        return replacing(anyTagRegex, in: separated, with: "")
    }

    /// Visible text of an HTML fragment: tags stripped, entities decoded
    /// once, and every run of whitespace collapsed to a single space.
    static func plainText(fromHTML html: String) -> String {
        decodeHTMLEntities(stripHTML(html))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Caps `text` at ``maxSnippetCharacters`` characters, ending with an
    /// ellipsis when it was cut.
    static func cappedSnippet(_ text: String, maxCharacters: Int = maxSnippetCharacters) -> String {
        guard text.count > maxCharacters else { return text }
        let cut = String(text.prefix(max(maxCharacters - 1, 0)))
        return cut.trimmingCharacters(in: .whitespacesAndNewlines) + "\u{2026}"
    }

    private static func replacing(_ regex: NSRegularExpression?, in text: String, with replacement: String) -> String {
        regex?.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text),
            withTemplate: replacement
        ) ?? text
    }

    /// Single-pass entity decoder shared with the page converter: every
    /// `&name;`, `&#NNN;` and `&#xHH;` is replaced exactly once from the
    /// original text, so `&amp;lt;` decodes to `&lt;` deterministically.
    /// Numeric references that are not meaningful text (NUL, surrogates,
    /// out-of-range values, control characters) stay as written.
    static func decodeHTMLEntities(_ text: String) -> String {
        WebHTMLEntities.decode(text, keepingInvalidNumericReferences: true)
    }
}
