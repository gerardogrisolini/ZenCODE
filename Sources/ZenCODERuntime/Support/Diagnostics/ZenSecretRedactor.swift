//
//  ZenSecretRedactor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Removes credential-like values from diagnostic text before it is written to a
/// local log or shown by `zen --doctor`. The redactor is deliberately
/// security-first: it prefers over-redacting a value to ever emitting a token,
/// API key, cookie, or Authorization header. It never performs any network or
/// file access and is safe to call from any thread.
public enum ZenSecretRedactor {
    /// Replacement token substituted for any recognized secret value.
    public static let placeholder = "[redacted]"

    /// Diagnostic strings are short by construction. Refuse to scan pathological
    /// inputs so a single malformed log line cannot dominate CPU; such input is
    /// replaced wholesale rather than emitted unredacted.
    private static let maximumInputBytes = 64 * 1_024

    /// Well-known credential shapes that are recognizable regardless of the
    /// surrounding text. These catch secrets that appear without a `key = value`
    /// framing (for example an OpenAI `sk-` key pasted into a URL or free text).
    private static let tokenFormatExpressions: [NSRegularExpression] = [
        // JSON Web Tokens (header.payload.signature).
        #"\beyJ[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}"#,
        // OpenAI / Anthropic style keys, including sk-proj- and sk-ant- prefixes.
        #"\bsk-[A-Za-z0-9_-]{12,}"#,
        // GitHub personal / OAuth / server tokens.
        #"\bgh[pousr]_[A-Za-z0-9]{20,}"#,
        // GitHub fine-grained personal access tokens.
        #"\bgithub_pat_[A-Za-z0-9_]{20,}"#,
        // Slack bot/user/app/refresh tokens.
        #"\bxox[baprs]-[A-Za-z0-9-]{8,}"#,
        // Google API keys.
        #"\bAIza[0-9A-Za-z_-]{20,}"#,
        // Google OAuth access tokens.
        #"\bya29\.[0-9A-Za-z_-]{20,}"#,
        // AWS access key identifiers.
        #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: []) }

    /// `Authorization: Bearer <token>` and `Basic <credentials>` forms, plus a
    /// bare `token <value>` handshake style.
    private static let schemeExpression = try! NSRegularExpression(
        pattern: #"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{4,}"#,
        options: []
    )

    /// `name = value` / `name: value` assignments whose name looks sensitive.
    /// The value may be quoted or unquoted; only the value is replaced so the
    /// surrounding structure (and the harmless key name) stays legible.
    private static let assignmentExpression = try! NSRegularExpression(
        pattern: #"(?i)\b((?:authorization|proxy[-_]?authorization|www[-_]?authenticate|set[-_]?cookie|cookie|x[-_]?api[-_]?key|api[-_]?key|apikey|access[-_]?token|refresh[-_]?token|id[-_]?token|auth[-_]?token|bearer[-_]?token|token|secret|client[-_]?secret|password|passwd|pwd|passphrase|credential|session[-_]?id|private[-_]?key)[A-Za-z0-9._-]*)(["']?\s*[:=]\s*)(?:"(?:\\.|[^"])*"|'(?:\\.|[^'])*'|[^\s,;&}\]\r\n]+)"#,
        options: []
    )

    /// URL user-info (`scheme://user:password@host`) never has a safe form.
    private static let urlUserInfoExpression = try! NSRegularExpression(
        pattern: #"://[^/\s:@]+:[^/\s@]+@"#,
        options: []
    )

    /// Returns `text` with every recognized secret replaced by ``placeholder``.
    /// Non-sensitive content is preserved so the result stays useful for
    /// diagnostics.
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else {
            return text
        }
        guard text.lengthOfBytes(using: .utf8) <= maximumInputBytes else {
            return placeholder
        }

        var result = text
        for expression in tokenFormatExpressions {
            result = replacing(expression, in: result, with: placeholder)
        }
        result = replacing(schemeExpression, in: result, with: "$1 \(placeholder)")
        result = replacing(assignmentExpression, in: result, with: "$1$2\(placeholder)")
        result = replacing(urlUserInfoExpression, in: result, with: "://\(placeholder)@")
        return result
    }

    private static func replacing(
        _ expression: NSRegularExpression,
        in source: String,
        with template: String
    ) -> String {
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return expression.stringByReplacingMatches(
            in: source,
            options: [],
            range: range,
            withTemplate: template
        )
    }
}
