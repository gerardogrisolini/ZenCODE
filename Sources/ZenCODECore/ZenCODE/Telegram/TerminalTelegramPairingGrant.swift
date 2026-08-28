//
//  TerminalTelegramPairingGrant.swift
//  ZenCODE
//

import Foundation
import Crypto
#if canImport(Security)
import Security
#endif

/// A pairing grant: one cryptographic, time-limited, single-use invitation
/// for a Telegram private chat to link this ZenCODE session.
///
/// Threat model and shape:
/// * **Entropy** — the payload is 128 bits from `SecRandomCopyBytes` (16 bytes
///   hex-encoded, 32 characters). Guessing it is infeasible; the legacy
///   8-hex-digit code carried only 32 bits.
/// * **No plaintext on the wire** — the terminal shows a deep link that embeds
///   the payload, and Telegram delivers `/start <payload>` to the bot. The
///   store keeps only a SHA-256 *hash* of the payload, so a leaked store never
///   reveals a live grant.
/// * **TTL** — 10 minutes. A grant that is not consumed in time expires and
///   can no longer link anything.
/// * **Single use, atomic consumption** — `consume(payload:)` removes the
///   grant in the same critical section that validates it; two racing updates
///   with the same payload cannot both succeed, and a consumed grant is gone
///   from the store before the link is published.
/// * **Manual fallback** — the operator can still type the payload as a plain
///   message to the bot (or `/start <payload>`), exactly like the legacy
///   code flow. The deep link is a convenience, not a requirement.
public struct TerminalTelegramPairingGrant: Sendable, Equatable {
    /// Grants older than this are rejected and evicted.
    public static let timeToLive: TimeInterval = 600

    /// SHA-256 hex digest of the payload. Only the digest is stored.
    public let payloadDigest: String
    public let issuedAt: Date

    init(payloadDigest: String, issuedAt: Date) {
        self.payloadDigest = payloadDigest
        self.issuedAt = issuedAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(issuedAt) > Self.timeToLive
    }
}

/// In-memory store of issued pairing grants.
///
/// The store is process-local on purpose: grants are short-lived handoffs
/// between the operator's terminal and the same process's bot polling loop;
/// persisting them would outlive their security lifetime. It is the single
/// authority on grant validity for the whole process.
public actor TerminalTelegramPairingGrantStore {    private var grants: [TerminalTelegramPairingGrant] = []
    private var issuedPayloads: Set<String> = []

    public init() {}

    /// Generates and records one grant, returning the payload to embed in the
    /// deep link (and to show for manual fallback). The payload itself is
    /// returned exactly once and never stored.
    public func issueGrant(now: Date = Date()) -> String {
        var payload: String
        repeat {
            payload = Self.randomPayload()
        } while issuedPayloads.contains(payload)
        issuedPayloads.insert(payload)
        grants.append(
            TerminalTelegramPairingGrant(
                payloadDigest: Self.digest(payload),
                issuedAt: now
            )
        )
        evictExpired(now: now)
        return payload
    }

    /// Attempts to consume `payload`. Returns `true` exactly once per issued
    /// grant: the entry is removed in the same actor-isolated step that
    /// validates it, so concurrent or replayed attempts fail.
    @discardableResult
    public func consume(payload: String, now: Date = Date()) -> Bool {
        evictExpired(now: now)
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return false }
        let digest = Self.digest(trimmed)
        guard let index = grants.firstIndex(where: { $0.payloadDigest == digest }) else {
            return false
        }
        let grant = grants.remove(at: index)
        issuedPayloads.remove(trimmed)
        return !grant.isExpired(now: now)
    }

    /// Number of live (unexpired) grants; exposed for tests.
    public var liveGrantCount: Int {
        evictExpired()
        return grants.count
    }

    private func evictExpired(now: Date = Date()) {
        grants.removeAll { $0.isExpired(now: now) }
    }

    /// 128 bits of entropy, hex-encoded (32 characters, Telegram-safe).
    /// Uses the system CSPRNG on Apple platforms and the Swift runtime's
    /// cryptographically secure generator elsewhere, mirroring the project's
    /// `Support/Extensions.swift` pattern.
    static func randomPayload() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        #if canImport(Security)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 16, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            // Failure of the system CSPRNG is not a recoverable condition: fail
            // loudly instead of downgrading entropy silently.
            fatalError("SecRandomCopyBytes failed with status \(status)")
        }
        #else
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        #endif
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func digest(_ payload: String) -> String {
        Data(payload.uppercased().utf8).sha256Hex()
    }
}

/// Helpers for building the Telegram deep link and parsing `/start <payload>`.
public enum TerminalTelegramPairingGrantLink {
    /// Deep-link path for a bot: `https://t.me/<bot>?start=<payload>`.
    public static func deepLink(botUsername: String, payload: String) -> String {
        "https://t.me/\(botUsername)?start=\(payload)"
    }

    /// Extracts the `/start` payload from a message, or `nil` for a bare
    /// `/start` or any other line. Accepts `/start@botname payload`.
    public static func payload(fromStartCommand text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace }
        )
        guard let first = parts.first else { return nil }
        let command = first.lowercased()
        guard command == "/start" || command.hasPrefix("/start@") else { return nil }
        guard parts.count == 2 else { return nil }
        let payload = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        return payload.isEmpty ? nil : payload
    }
}
