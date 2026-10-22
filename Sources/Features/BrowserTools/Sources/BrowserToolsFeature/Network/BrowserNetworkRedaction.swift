//
//  BrowserNetworkRedaction.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

// MARK: - Network Redaction

enum BrowserNetworkURLRedaction {
    private static let maximumRawURLBytes = 8 * 1_024
    private static let sensitiveQueryNameFragments = [
        "auth", "bearer", "code", "cookie", "credential", "key", "password",
        "proxy", "secret", "session", "sig", "signature", "token",
    ]

    static func apply(to rawURL: String) -> String {
        guard rawURL.lengthOfBytes(using: .utf8) <= maximumRawURLBytes else { return "<redacted-url>" }
        guard var components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              !scheme.isEmpty
        else {
            // A malformed URL cannot be reliably decomposed into credentials,
            // query, and fragment. Never fall back to the raw value.
            return "<redacted-url>"
        }

        // data: and blob: URLs often embed document data in their path. They
        // are valid browser requests, but do not have a safe diagnostic form.
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

        guard let result = components.string else { return "<redacted-url>" }
        return BrowserNetworkOutputBounds.clip(result, maximumBytes: BrowserNetworkOutputBounds.maximumURLBytes)
    }
}

enum BrowserNetworkSensitiveTextRedaction {
    private static let sensitiveNameFragments = [
        "authorization", "cookie", "credential", "key", "password", "proxy-auth",
        "secret", "session", "token",
    ]

    private static let bearerExpression = try! NSRegularExpression(
        pattern: #"\b(?:bearer|basic)\s+[A-Za-z0-9._~+/=-]+"#,
        options: [.caseInsensitive]
    )
    private static let assignmentExpression = try! NSRegularExpression(
        pattern: #"\b((?:authorization|proxy[-_]?auth(?:enticate|entication|orization)?|set[-_]?cookie|cookie|(?:access[-_]?|api[-_]?)?token|(?:api[-_]?)?key|secret|password|credential)[A-Za-z0-9._-]*[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"])*\"|'(?:\\.|[^'])*'|[^\s,;&}\]\r\n]+)"#,
        options: [.caseInsensitive]
    )
    private static let exposedNameExpression = try! NSRegularExpression(
        pattern: #"\b(?:authorization|proxy[-_]?auth(?:enticate|entication|orization)?|set[-_]?cookie|cookie|(?:access[-_]?|api[-_]?)?token|(?:api[-_]?)?key|secret|password|credential)\b"#,
        options: [.caseInsensitive]
    )

    static func isSensitiveName(_ rawName: String) -> Bool {
        let normalized = rawName.lowercased()
        return sensitiveNameFragments.contains(where: normalized.contains)
            || normalized.contains("proxy_auth")
    }

    static func redact(_ source: String) -> String {
        let jsonRedacted = redactJSONIfPossible(source) ?? source
        let withoutBearer = replacing(bearerExpression, in: jsonRedacted, with: "[redacted]")
        return replacing(assignmentExpression, in: withoutBearer, with: "$1\"[redacted]\"")
    }

    static func redactAndClip(_ source: String, maximumBytes: Int) -> String {
        let boundedSource = BrowserNetworkOutputBounds.clip(source, maximumBytes: maximumBytes)
        return BrowserNetworkOutputBounds.clip(redact(boundedSource), maximumBytes: maximumBytes)
    }

    /// Header values have no need to reveal credential-like field names. This
    /// removes those names in addition to redacting their values, so a server
    /// cannot echo an otherwise omitted sensitive header through a safe header
    /// such as Vary or Access-Control-Allow-Headers.
    static func redactHeaderValue(_ source: String) -> String {
        replacing(exposedNameExpression, in: redact(source), with: "[redacted]")
    }

    private static func redactJSONIfPossible(_ source: String) -> String? {
        guard let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else {
            return nil
        }
        let redactedObject = redactJSONValue(object)
        guard JSONSerialization.isValidJSONObject(redactedObject),
              let serialized = try? JSONSerialization.data(withJSONObject: redactedObject, options: [.sortedKeys])
        else {
            return nil
        }
        return String(data: serialized, encoding: .utf8)
    }

    private static func redactJSONValue(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            var redacted: [String: Any] = [:]
            for (key, child) in dictionary {
                redacted[key] = isSensitiveName(key) ? "[redacted]" : redactJSONValue(child)
            }
            return redacted
        }
        if let array = value as? [Any] {
            return array.map(redactJSONValue)
        }
        if let string = value as? String,
           string.lowercased().hasPrefix("http")
        {
            return BrowserNetworkURLRedaction.apply(to: string)
        }
        return value
    }

    private static func replacing(_ expression: NSRegularExpression, in source: String, with template: String) -> String {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(in: source, options: [], range: range, withTemplate: template)
    }
}

enum BrowserNetworkOutputBounds {
    static let maximumURLBytes = 2_048
    static let maximumMethodBytes = 64
    static let maximumResourceTypeBytes = 64
    static let maximumMIMETypeBytes = 256
    static let maximumFailureBytes = 1_024

    static func clipOptional(_ value: String?, maximumBytes: Int) -> String? {
        value.map { clip($0, maximumBytes: maximumBytes) }
    }

    static func clip(_ value: String, maximumBytes: Int) -> String {
        clipWithMetadata(value, maximumBytes: maximumBytes).value
    }

    static func clipWithMetadata(_ value: String, maximumBytes: Int) -> (value: String, truncated: Bool) {
        guard value.lengthOfBytes(using: .utf8) > maximumBytes else { return (value, false) }
        let ellipsis = "…"
        let ellipsisBytes = ellipsis.lengthOfBytes(using: .utf8)
        guard maximumBytes >= ellipsisBytes else { return ("", true) }
        let contentBudget = maximumBytes - ellipsisBytes
        let result = value.prefixFitting(utf8Bytes: contentBudget)
        return (result + ellipsis, true)
    }
}

enum BrowserNetworkValue {
    static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return truncatedInteger(value) }
        if let value = value as? NSNumber {
            if let exact = integralInt64(value) { return Int(exactly: exact) }
            return truncatedInteger(value.doubleValue)
        }
        return nil
    }

    static func nonNegativeInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return max(0, value) }
        if let value = value as? Int { return Int64(max(0, value)) }
        if let value = value as? Double { return truncatedInt64(value).map { max(0, $0) } }
        if let value = value as? NSNumber {
            if let exact = integralInt64(value) { return max(0, exact) }
            return truncatedInt64(value.doubleValue).map { max(0, $0) }
        }
        return nil
    }

    /// Integral `NSNumber`s (including those decoded by `JSONSerialization`)
    /// are read exactly: routing them through `Double` would lose precision
    /// above 2^53. Floating `NSNumber`s return nil and take the Double path,
    /// which rejects NaN and infinity. The `objCType` check is portable to
    /// swift-corelibs-foundation, where `CFNumberIsFloatType` is unavailable.
    private static func integralInt64(_ value: NSNumber) -> Int64? {
        switch value.objCType.pointee {
        case 0x63, 0x73, 0x69, 0x6C, 0x71: // c s i l q
            return value.int64Value
        case 0x43, 0x53, 0x49, 0x4C: // C S I L
            return value.int64Value
        case 0x51: // Q: unsigned 64-bit may exceed Int64
            return Int64(exactly: value.uint64Value)
        default:
            return nil
        }
    }

    /// `Int(_: Double)` traps on NaN, infinity, and values at or beyond the
    /// integer range (including `Double(Int.max)`, which rounds up to 2^63).
    /// Page-influenced CDP payloads must never be able to reach that trap.
    private static func truncatedInteger(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded(.towardZero))
    }

    private static func truncatedInt64(_ value: Double) -> Int64? {
        guard value.isFinite else { return nil }
        return Int64(exactly: value.rounded(.towardZero))
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? NSNumber {
            let result = value.doubleValue
            return result.isFinite ? result : nil
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    static func headerString(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}
