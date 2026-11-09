import Foundation

extension WebMarkdownRenderer {
    // MARK: Links and URLs

    /// Absolute URL for a rendered anchor, nil when it must render as text
    /// (`javascript:`, `mailto:`, unresolvable, other schemes).
    func linkTarget(_ href: String) -> String? {
        guard let url = Self.resolve(href, against: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme) else {
            return nil
        }
        return url.absoluteString
    }

    /// Absolute http(s) URL of an image source; `data:` and others are dropped.
    func resourceURL(_ source: String) -> String? {
        guard let url = Self.resolve(source, against: baseURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url.absoluteString
    }

    static func resolve(_ raw: String, against base: URL?) -> URL? {
        let cleaned = cleanedURLString(raw)
        guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              url.scheme != nil else {
            return nil
        }
        return url
    }

    /// Strips leading/trailing whitespace and embedded tabs/newlines, as the
    /// URL standard does.
    static func cleanedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            value.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        }
        return value
    }

    static func withoutFragment(_ url: String) -> String {
        guard let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }
}
