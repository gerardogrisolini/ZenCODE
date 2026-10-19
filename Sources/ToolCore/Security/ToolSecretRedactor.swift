import Foundation

/// Dependency-safe redaction primitives shared by feature and core packages.
/// Keep environment values out of diagnostics whenever their key is
/// credential-like; callers receive a stable ordering for testable logs.
public enum ToolSecretRedactor {
    public static let placeholder = "[REDACTED]"

    private static let sensitiveKeyFragments = [
        "token", "secret", "auth", "key", "password", "credential", "passphrase"
    ]

    public static func redactedEnvironmentDescription(_ environment: [String: String]) -> String {
        let entries = environment.keys.sorted().map { key in
            let lowercasedKey = key.lowercased()
            let isSensitive = sensitiveKeyFragments.contains { lowercasedKey.contains($0) }
            return "\(key): \(isSensitive ? placeholder : environment[key, default: ""])"
        }
        return "[\(entries.joined(separator: ", "))]"
    }
}
