//
//  TerminalTelegramArtifactConsent.swift
//  ZenCODE
//

import Foundation
import Crypto
import ToolCore

/// Explicit outbound consent for one artifact upload.
///
/// Every outbound document needs one: the operator selected the artifact
/// (`/diff`, `/report`, or an attachment reply) and then tapped an explicit
/// confirmation button. The grant is single-use, chat-scoped, bound to the
/// exact artifact identity (path + size + mtime identity) and short-lived,
/// so a stale confirmation can never authorize a newer, different file and a
/// replayed callback can never send twice.
public actor TerminalTelegramArtifactConsentBroker {
    /// Lifetime of an unconsumed consent offer.
    static let offerLifetime: TimeInterval = 120
    /// Maximum simultaneously pending offers per chat.
    static let maximumPendingOffersPerChat = 4

    struct Offer: Sendable, Equatable {
        let id: String
        let chatID: Int64
        let userID: Int64
        let routeLease: TerminalTelegramRouteLease
        let artifact: TerminalTelegramArtifact
        /// Immutable identity captured before the offer is shown to the user.
        let fingerprint: ArtifactFingerprint
        let cleanupAfterUse: Bool
        let issuedAt: Date
        var expiresAt: Date { issuedAt.addingTimeInterval(offerLifetime) }

        static func == (lhs: Offer, rhs: Offer) -> Bool {
            lhs.id == rhs.id
                && lhs.chatID == rhs.chatID
                && lhs.userID == rhs.userID
                && lhs.routeLease == rhs.routeLease
                && lhs.artifact == rhs.artifact
                && lhs.fingerprint == rhs.fingerprint
                && lhs.cleanupAfterUse == rhs.cleanupAfterUse
        }
    }

    /// Identity of the artifact the consent was issued for: the exact bytes
    /// are re-validated at consume time through this fingerprint.
    struct ArtifactFingerprint: Sendable, Equatable, Hashable {
        let path: String
        let size: Int
        let modifiedAtNanoseconds: Int64
        let sha256: String

        init(
            path: String,
            size: Int,
            modifiedAtNanoseconds: Int64,
            sha256: String = ""
        ) {
            self.path = path
            self.size = size
            self.modifiedAtNanoseconds = modifiedAtNanoseconds
            self.sha256 = sha256
        }
    }

    private var offers: [Offer] = []
    private let now: @Sendable () -> Date

    /// Overridable clock for tests.
    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Offers

    /// Records a consent offer for `artifact` and returns the offer id to
    /// embed in the confirmation keyboard. Returns `nil` when the chat
    /// already holds too many pending offers (fail-closed: the operator is
    /// asked to expire or use one first).
    func offerConsent(
        artifact: TerminalTelegramArtifact,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        cleanupAfterUse: Bool = false
    ) throws -> String? {
        try expireStaleOffers()
        let pending = offers.filter { $0.chatID == chatID }
        guard pending.count < Self.maximumPendingOffersPerChat else {
            return nil
        }
        guard let fingerprint = Self.fingerprint(of: artifact) else {
            throw TerminalTelegramControlError.artifactPathRejected
        }
        let offer = Offer(
            id: "zencode-artifact-\(UUID().uuidString.prefix(8).lowercased())",
            chatID: chatID,
            userID: userID,
            routeLease: routeLease,
            artifact: artifact,
            fingerprint: fingerprint,
            cleanupAfterUse: cleanupAfterUse,
            issuedAt: now()
        )
        offers.append(offer)
        return offer.id
    }

    /// Single-use consumption. The callback must match an unexpired offer for
    /// the same chat and user, and the artifact on disk must still match the
    /// fingerprint the offer was issued for; otherwise the consent is refused
    /// (fail-closed) and the offer is dropped so it cannot be retried with a
    /// different file underneath.
    func consume(
        offerID: String,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        artifactFingerprint: ArtifactFingerprint?
    ) throws -> Offer? {
        try expireStaleOffers()
        guard let index = offers.firstIndex(where: { $0.id == offerID }) else {
            return nil
        }
        let offer = offers.remove(at: index)
        guard offer.chatID == chatID, offer.userID == userID,
              offer.routeLease == routeLease else {
            removeOwnedArtifact(offer)
            return nil
        }
        guard let current = Self.fingerprint(of: offer.artifact),
              current == offer.fingerprint,
              artifactFingerprint.map({ $0 == offer.fingerprint }) ?? true else {
            removeOwnedArtifact(offer)
            return nil
        }
        return offer
    }

    func pendingOfferIDs(chatID: Int64) -> [String] {
        offers
            .filter { $0.chatID == chatID }
            .map(\.id)
    }

    /// The still-pending offer with this id, if any.
    func pendingOffer(offerID: String, chatID: Int64) -> Offer? {
        offers.first { $0.id == offerID && $0.chatID == chatID }
    }

    /// Spends an offer without uploading. Idempotent.
    func cancel(offerID: String, chatID: Int64) {
        let removed = offers.filter { $0.id == offerID && $0.chatID == chatID }
        offers.removeAll { $0.id == offerID && $0.chatID == chatID }
        removed.forEach(removeOwnedArtifact)
    }

    /// Drops every pending offer (logout, unlink, teardown).
    func reset() {
        offers.forEach(removeOwnedArtifact)
        offers.removeAll()
    }

    private func expireStaleOffers() throws {
        let current = now()
        let expired = offers.filter { $0.expiresAt < current }
        offers.removeAll { $0.expiresAt < current }
        expired.forEach(removeOwnedArtifact)
    }

    private func removeOwnedArtifact(_ offer: Offer) {
        guard offer.cleanupAfterUse else { return }
        try? FileManager.default.removeItem(at: offer.artifact.fileURL)
    }

    static func fingerprint(
        of artifact: TerminalTelegramArtifact
    ) -> ArtifactFingerprint? {
        guard let values = try? artifact.fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true,
              let size = values.fileSize,
              size >= 0,
              size <= TerminalTelegramMultipartForm.maximumUploadFileBytes,
              let handle = try? FileHandle(forReadingFrom: artifact.fileURL) else {
            return nil
        }
        defer { try? handle.close() }
        var hasher = SHA256()
        var consumed = 0
        do {
            while let chunk = try handle.read(upToCount: TerminalTelegramMultipartForm.streamingChunkBytes),
                  !chunk.isEmpty {
                consumed += chunk.count
                guard consumed <= size else { return nil }
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        guard consumed == size else { return nil }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ArtifactFingerprint(
            path: artifact.fileURL.resolvingSymlinksInPath().path,
            size: size,
            modifiedAtNanoseconds: values.contentModificationDate.map {
                Int64(($0.timeIntervalSince1970 * 1_000_000_000).rounded())
            } ?? 0,
            sha256: digest
        )
    }
}

/// Fail-closed consent keyboard rendered under a consent offer.
enum TerminalTelegramArtifactConsentKeyboard {
    static let callbackPrefix = "zencode:artifact:"

    /// Builds the two-button keyboard: an explicit confirm and an explicit
    /// cancel. Both buttons clear the offer; only the first uploads.
    static func markup(offerID: String) -> TerminalTelegramReplyMarkup {
        .inlineKeyboard([[
            TerminalTelegramInlineKeyboardButton(
                text: "Send file",
                callbackData: callbackPrefix + "send:" + offerID
            ),
            TerminalTelegramInlineKeyboardButton(
                text: "Cancel",
                callbackData: callbackPrefix + "cancel:" + offerID
            ),
        ]])
    }

    static func action(fromCallbackData data: String) -> (
        action: Action, offerID: String
    )? {
        guard data.hasPrefix(callbackPrefix) else { return nil }
        let payload = String(data.dropFirst(callbackPrefix.count))
        let parts = payload.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        switch parts[0] {
        case "send": return (.send, String(parts[1]))
        case "cancel": return (.cancel, String(parts[1]))
        default: return nil
        }
    }

    enum Action: Equatable {
        case send
        case cancel
    }
}
