import Foundation

/// Opaque, process-independent reference to an Accessibility element.
///
/// The feature worker is one-shot, so a reference must be resolvable by a new
/// process. It records the owning pid, an anchor for the window (the Quartz
/// window ID when it was verifiable, otherwise the index in the app's AX window
/// list plus a title prefix), the child-index path below that window, the role
/// expected at the end of the path, and a fingerprint of that element. Grammar:
///
///     p<pid>.w<window_id>:<path>:<role>:<fingerprint>
///     p<pid>.i<window_index>[.t<base64url title prefix>]:<path>:<role>:<fingerprint>
///
/// `<path>` is a dot-separated list of `kAXChildrenAttribute` indices (empty for
/// the window itself). Integers are canonical (no sign, no leading zeros), so
/// every reference has exactly one spelling. `<fingerprint>` is eight lowercase
/// hex digits of a 32-bit FNV-1a hash of the element's role, subrole, title,
/// description, and identifier (`fingerprint(of:)`): when the path now leads to
/// a different element (siblings were inserted or removed), the fingerprint no
/// longer matches and the reference is stale. The value and the frame are left
/// out because they change while the element stays the same.
struct DesktopElementReference: Equatable, Sendable {
    enum WindowAnchor: Equatable, Sendable {
        case windowID(UInt32)
        case windowIndex(Int, titlePrefix: String?)
    }

    static let maximumLength = 1024
    static let maximumPathDepth = 128
    static let maximumChildIndex = 999_999
    static let maximumWindowIndex = 500
    static let maximumRoleLength = 64
    static let titlePrefixLength = 64
    static let fingerprintLength = 8

    let pid: Int32
    let window: WindowAnchor
    let path: [Int]
    let role: String
    let fingerprint: String

    init(pid: Int32, window: WindowAnchor, path: [Int], role: String, fingerprint: String) {
        self.pid = pid
        if case let .windowIndex(index, title) = window {
            self.window = .windowIndex(index, titlePrefix: Self.titlePrefix(title))
        } else {
            self.window = window
        }
        self.path = path
        self.role = role
        self.fingerprint = fingerprint
    }

    /// The encoded reference, or nil when a component cannot be represented
    /// (invalid pid, role characters, fingerprint, path bounds) or the result
    /// is too long.
    var encoded: String? {
        guard pid > 0, Self.isValidRole(role), Self.isValidFingerprint(fingerprint),
              path.count <= Self.maximumPathDepth,
              path.allSatisfy({ (0...Self.maximumChildIndex).contains($0) }) else {
            return nil
        }
        var head = "p\(pid)"
        switch window {
        case let .windowID(id):
            guard id > 0 else { return nil }
            head += ".w\(id)"
        case let .windowIndex(index, title):
            guard (0...Self.maximumWindowIndex).contains(index) else { return nil }
            head += ".i\(index)"
            if let title { head += ".t" + Self.base64URL(title) }
        }
        let result = head + ":" + path.map(String.init).joined(separator: ".") + ":" + role + ":" + fingerprint
        return result.utf8.count <= Self.maximumLength ? result : nil
    }

    init(parsing raw: String) throws {
        guard raw.utf8.count <= Self.maximumLength else {
            throw Self.malformed("must contain at most \(Self.maximumLength) characters")
        }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 4 else { throw Self.malformed("has an unexpected format") }

        let head = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(head.count), head[0].first == "p",
              let pidValue = Self.canonicalInteger(head[0].dropFirst(), maximum: Int(Int32.max)), pidValue > 0 else {
            throw Self.malformed("has an invalid process component")
        }

        let anchor: WindowAnchor
        switch head[1].first {
        case "w":
            guard head.count == 2,
                  let id = Self.canonicalInteger(head[1].dropFirst(), maximum: Int(UInt32.max)), id > 0 else {
                throw Self.malformed("has an invalid window component")
            }
            anchor = .windowID(UInt32(id))
        case "i":
            guard let index = Self.canonicalInteger(head[1].dropFirst(), maximum: Self.maximumWindowIndex) else {
                throw Self.malformed("has an invalid window component")
            }
            var title: String?
            if head.count == 3 {
                guard head[2].first == "t", let decoded = Self.decodeBase64URL(head[2].dropFirst()),
                      Self.titlePrefix(decoded) == decoded else {
                    throw Self.malformed("has an invalid window title component")
                }
                title = decoded
            }
            anchor = .windowIndex(index, titlePrefix: title)
        default:
            throw Self.malformed("has an invalid window component")
        }

        var path: [Int] = []
        if !parts[1].isEmpty {
            let components = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard components.count <= Self.maximumPathDepth else { throw Self.malformed("has a path that is too deep") }
            for component in components {
                guard let index = Self.canonicalInteger(component, maximum: Self.maximumChildIndex) else {
                    throw Self.malformed("has an invalid path component")
                }
                path.append(index)
            }
        }

        let role = String(parts[2])
        guard Self.isValidRole(role) else { throw Self.malformed("has an invalid role component") }
        let fingerprint = String(parts[3])
        guard Self.isValidFingerprint(fingerprint) else { throw Self.malformed("has an invalid fingerprint component") }

        self.init(pid: Int32(pidValue), window: anchor, path: path, role: role, fingerprint: fingerprint)
    }

    // MARK: Fingerprint

    /// The fingerprint of a described element: its role, subrole, title,
    /// description, and identifier (blank texts count as absent). Deterministic
    /// across processes, unlike `hashValue`.
    static func fingerprint(of element: DesktopElementInfo) -> String {
        fingerprint(
            role: element.role, subrole: element.subrole, title: element.title,
            description: element.description, identifier: element.identifier
        )
    }

    static func fingerprint(
        role: String, subrole: String?, title: String?, description: String?, identifier: String?
    ) -> String {
        var hash: UInt32 = 0x811C_9DC5
        func mix(_ byte: UInt8) {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        for (index, field) in [role, subrole, title, description, identifier].enumerated() {
            if index > 0 { mix(0x1F) }
            guard let field, !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                mix(0x00)
                continue
            }
            mix(0x01)
            field.utf8.forEach(mix)
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: fingerprintLength - hex.count) + hex
    }

    static func isValidFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.utf8.count == fingerprintLength
            && fingerprint.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    // MARK: Window anchor

    /// The anchor of a window without a verified Quartz window ID: its index in
    /// the app's AX window list plus its title prefix. Nil without an index, or
    /// when reading the title failed (a timeout or an AX error, not an absent
    /// title): an anchor without a title would claim the window is untitled and
    /// later match only an untitled window, so no ref is better than a wrong one.
    static func indexAnchor(index: Int?, title: String?, titleReadFailed: Bool) -> WindowAnchor? {
        guard let index, !titleReadFailed else { return nil }
        return .windowIndex(index, titlePrefix: titlePrefix(title))
    }

    /// Picks the AX window an index anchor designates. The recorded index wins
    /// when its title still agrees; otherwise a unique title-prefix match among
    /// the current windows is accepted (windows reorder as focus changes). An
    /// untitled anchor accepts only the window at its index, and only while
    /// that window is still untitled.
    static func resolveWindowIndex(titles: [String?], index: Int, titlePrefix: String?) -> Int? {
        if titles.indices.contains(index), titleMatches(titles[index], prefix: titlePrefix) {
            return index
        }
        guard titlePrefix != nil else { return nil }
        let matches = titles.indices.filter { titleMatches(titles[$0], prefix: titlePrefix) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// True when `title` has the recorded prefix; a nil prefix (untitled
    /// anchor) matches only an untitled window.
    static func titleMatches(_ title: String?, prefix: String?) -> Bool {
        titlePrefix(title) == prefix
    }

    static func titlePrefix(_ title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        return String(title.prefix(titlePrefixLength))
    }

    static func isValidRole(_ role: String) -> Bool {
        (1...maximumRoleLength).contains(role.utf8.count)
            && role.utf8.allSatisfy { byte in
                (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                    || (byte >= 0x61 && byte <= 0x7A) || byte == 0x5F
            }
    }

    private static func canonicalInteger(_ text: Substring, maximum: Int) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 10,
              text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              text == "0" || text.first != "0",
              let value = Int(text), value <= maximum else {
            return nil
        }
        return value
    }

    private static func base64URL(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ token: Substring) -> String? {
        guard !token.isEmpty,
              token.utf8.allSatisfy({ byte in
                  (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                      || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
              }) else {
            return nil
        }
        var base64 = token.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf8),
              base64URL(text) == token else {
            return nil
        }
        return text
    }

    private static func malformed(_ reason: String) -> DesktopControlError {
        .invalidArgument("element_ref", "\(reason); pass a ref returned by list_elements.")
    }
}
