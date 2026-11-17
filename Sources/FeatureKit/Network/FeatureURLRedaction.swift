//
//  FeatureURLRedaction.swift
//  FeatureKit
//
//  The diagnostic form of a URL that network-aware features report.
//

import Foundation

/// Redacts a URL before a feature reports it in a diagnostic or an error.
///
/// Credentials and the fragment are dropped, the values of query items whose
/// name holds a sensitive fragment (``sensitiveQueryNameFragments``) are
/// masked, `data:` and `blob:` URLs keep only their scheme, and a URL too long
/// or too malformed to decompose reliably is fully redacted. It applies no
/// policy about which URLs a feature may fetch, and it does not bound the
/// length of the result: each feature does that its own way.
public enum FeatureURLRedaction {
    /// The replacement of a URL that cannot be redacted reliably.
    public static let redactedURL = "<redacted-url>"
    /// URLs longer than this many UTF-8 bytes are never decomposed.
    public static let maximumRawURLBytes = 8 * 1_024
    /// A query item whose lowercased name contains one of these has its value
    /// masked.
    public static let sensitiveQueryNameFragments = [
        "auth", "bearer", "code", "cookie", "credential", "key", "password",
        "proxy", "secret", "session", "sig", "signature", "token",
    ]

    /// The redacted form of `rawURL`.
    public static func redacted(_ rawURL: String) -> String {
        guard rawURL.lengthOfBytes(using: .utf8) <= maximumRawURLBytes else { return redactedURL }
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            // A malformed URL cannot be reliably decomposed into credentials,
            // query, and fragment. Never fall back to the raw value.
            return redactedURL
        }

        // data: and blob: URLs often embed document data in their path. They
        // are valid requests, but do not have a safe diagnostic form.
        if scheme == "data" || scheme == "blob" {
            return "\(scheme):[redacted]"
        }

        components.user = nil
        components.password = nil
        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                let normalizedName = item.name.lowercased()
                guard !sensitiveQueryNameFragments.contains(where: normalizedName.contains) else {
                    return URLQueryItem(name: item.name, value: "[redacted]")
                }
                return item
            }
        } else if components.query != nil {
            // Preserve no query data if it was too malformed for URLComponents
            // to parse item-by-item.
            components.query = nil
        }

        return components.string ?? redactedURL
    }
}
