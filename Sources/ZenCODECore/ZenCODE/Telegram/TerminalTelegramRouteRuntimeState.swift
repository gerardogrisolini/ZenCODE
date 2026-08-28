//
//  TerminalTelegramRouteRuntimeState.swift
//  ZenCODE
//

import Foundation

/// Per-route volatile state. Every operation revalidates the route generation
/// before touching storage, so revocation/rebind/close fences queued work,
/// ledgers, drafts and reply targets together.
public actor TerminalTelegramRouteRuntimeState {
    public struct ReplyTarget: Sendable, Equatable {
        public let roomID: String
        public let targetID: String
        public init(roomID: String, targetID: String) {
            self.roomID = roomID
            self.targetID = targetID
        }
    }

    private struct Bucket {
        var queue: [String] = []
        var ledger: Set<UUID> = []
        var draftIDs: Set<Int> = []
        var replyTargets: [Int: ReplyTarget] = [:]
    }

    private let router: TerminalTelegramSessionRouter
    private var buckets: [TerminalTelegramRouteLease: Bucket] = [:]

    public init(router: TerminalTelegramSessionRouter) { self.router = router }

    public func enqueue(_ value: String, lease: TerminalTelegramRouteLease) async throws {
        try await router.validate(lease)
        buckets[lease, default: Bucket()].queue.append(value)
    }

    public func dequeue(lease: TerminalTelegramRouteLease) async throws -> String? {
        try await router.validate(lease)
        guard buckets[lease]?.queue.isEmpty == false else { return nil }
        return buckets[lease]?.queue.removeFirst()
    }

    /// Returns true once per route/message identity.
    public func admitLedgerID(_ id: UUID, lease: TerminalTelegramRouteLease) async throws -> Bool {
        try await router.validate(lease)
        return buckets[lease, default: Bucket()].ledger.insert(id).inserted
    }

    public func registerDraft(_ draftID: Int, lease: TerminalTelegramRouteLease) async throws {
        try await router.validate(lease)
        buckets[lease, default: Bucket()].draftIDs.insert(draftID)
    }

    public func ownsDraft(_ draftID: Int, lease: TerminalTelegramRouteLease) async -> Bool {
        guard (try? await router.validate(lease)) != nil else { return false }
        return buckets[lease]?.draftIDs.contains(draftID) == true
    }

    public func registerReplyTarget(
        _ target: ReplyTarget,
        messageID: Int,
        lease: TerminalTelegramRouteLease
    ) async throws {
        try await router.validate(lease)
        guard target.roomID == lease.key.roomID else { throw TerminalTelegramRouteDenial.unauthorized }
        buckets[lease, default: Bucket()].replyTargets[messageID] = target
    }

    public func replyTarget(
        messageID: Int,
        lease: TerminalTelegramRouteLease
    ) async -> ReplyTarget? {
        guard (try? await router.validate(lease)) != nil else { return nil }
        return buckets[lease]?.replyTargets[messageID]
    }

    /// Explicit teardown drops only one route. A delayed operation carrying its
    /// retired lease fails validation and cannot recreate the bucket.
    public func teardown(lease: TerminalTelegramRouteLease) {
        buckets.removeValue(forKey: lease)
    }
}
