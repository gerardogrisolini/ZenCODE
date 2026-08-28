//
//  TerminalTelegramSessionRouter.swift
//  ZenCODE
//

import Foundation
import Synchronization
import ToolCore

/// Stable identity of one Telegram-to-ZenCODE session route. `topicID == nil`
/// denotes the chat fallback route; it never aliases a concrete topic.
public struct TerminalTelegramRouteKey: Codable, Hashable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let topicID: Int?
    public let roomID: String

    public init(chatID: Int64, userID: Int64, topicID: Int? = nil, roomID: String) {
        self.chatID = chatID
        self.userID = userID
        self.topicID = topicID
        self.roomID = roomID
    }
}

public enum TerminalTelegramChatKind: String, Codable, Sendable {
    case privateChat = "private"
    case group
    case supergroup

    init(wireValue: String) {
        self = Self(rawValue: wireValue) ?? .group
    }

    var isPrivate: Bool { self == .privateChat }
}

public enum TerminalTelegramRouteLifecycle: String, Codable, Sendable {
    case active
    case closed
    case deleted
}

/// Persisted ACL and lifecycle for a route. Authorization always requires the
/// route owner or an explicit member; Telegram UI state is never consulted.
public struct AgentTelegramRouteManifest: Codable, Equatable, Sendable {
    public let chatID: Int64
    public let ownerUserID: Int64
    public let topicID: Int?
    public let roomID: String
    public let chatKind: TerminalTelegramChatKind
    public let memberUserIDs: [Int64]
    public let lifecycle: TerminalTelegramRouteLifecycle
    public let generation: UInt64

    public init(
        chatID: Int64,
        ownerUserID: Int64,
        topicID: Int? = nil,
        roomID: String,
        chatKind: TerminalTelegramChatKind = .privateChat,
        memberUserIDs: [Int64] = [],
        lifecycle: TerminalTelegramRouteLifecycle = .active,
        generation: UInt64 = 1
    ) {
        self.chatID = chatID
        self.ownerUserID = ownerUserID
        self.topicID = topicID
        self.roomID = roomID
        self.chatKind = chatKind
        self.memberUserIDs = Array(Set(memberUserIDs.filter { $0 != ownerUserID })).sorted()
        self.lifecycle = lifecycle
        self.generation = max(1, generation)
    }

    public func allows(userID: Int64) -> Bool {
        lifecycle == .active && (ownerUserID == userID || memberUserIDs.contains(userID))
    }
}

public struct TerminalTelegramRouteLease: Hashable, Sendable {
    public let key: TerminalTelegramRouteKey
    public let generation: UInt64
    /// Concrete topic carried by the inbound update. It can differ from the ACL
    /// key's topic when a chat-wide fallback route authorizes a forum topic.
    public let effectiveMessageThreadID: Int?

    public init(
        key: TerminalTelegramRouteKey,
        generation: UInt64,
        effectiveMessageThreadID: Int? = nil
    ) {
        self.key = key
        self.generation = generation
        self.effectiveMessageThreadID = effectiveMessageThreadID
    }
}

/// Revocable ownership token carried by delayed Telegram work. It combines the
/// complete route lease with a per-owner epoch: route revocation fails the
/// validator, while turn replacement calls `invalidate()` even when the route
/// generation itself did not change.
public final class TerminalTelegramWireFence: Sendable {
    public let lease: TerminalTelegramRouteLease
    public let lifecycleEpoch: UUID
    private let isCurrent = Mutex(true)
    private let validateLease: @Sendable (TerminalTelegramRouteLease) async throws -> Void

    public init(
        lease: TerminalTelegramRouteLease,
        lifecycleEpoch: UUID,
        validateLease: @escaping @Sendable (TerminalTelegramRouteLease) async throws -> Void
    ) {
        self.lease = lease
        self.lifecycleEpoch = lifecycleEpoch
        self.validateLease = validateLease
    }

    public func invalidate() {
        isCurrent.withLock { $0 = false }
    }

    public func validate(chatID: Int64, topicID: Int?) async throws {
        guard isCurrent.withLock({ $0 }),
              lease.key.chatID == chatID,
              lease.effectiveMessageThreadID == topicID else {
            throw CancellationError()
        }
        try await validateLease(lease)
        guard isCurrent.withLock({ $0 }), !Task.isCancelled else {
            throw CancellationError()
        }
    }

    /// Compatibility validation for non-route call sites. It still binds the
    /// concrete topic captured by the lease rather than defaulting to a root
    /// topic.
    public func validate(chatID: Int64) async throws {
        try await validate(chatID: chatID, topicID: lease.effectiveMessageThreadID)
    }
}

public enum TerminalTelegramRouteDenial: Error, Equatable, Sendable {
    case groupsNotEnabled
    case noRoute
    case routeClosed
    case unauthorized
    case staleGeneration
    case ownerCannotBeRevoked
}

/// Actor-serialized persistent route/ACL authority. All read-modify-write
/// operations commit the new snapshot before publishing it in memory.
public actor TerminalTelegramSessionRouter {
    public typealias Persist = @Sendable ([AgentTelegramRouteManifest]) throws -> Void

    private var routes: [AgentTelegramRouteManifest]
    private var groupsEnabled: Bool
    private let persist: Persist

    public init(
        routes: [AgentTelegramRouteManifest] = [],
        groupsEnabled: Bool = false,
        persist: @escaping Persist = { _ in }
    ) {
        self.routes = Self.normalized(routes)
        self.groupsEnabled = groupsEnabled
        self.persist = persist
    }

    public func snapshot() -> [AgentTelegramRouteManifest] { routes }

    /// Imports the latest atomically-decoded persisted projection before ingress
    /// resolution. Mutations still commit only through this actor; this hook is
    /// required because setup/tests may replace settings while a TUI exists.
    public func refresh(
        routes: [AgentTelegramRouteManifest],
        groupsEnabled: Bool
    ) {
        self.routes = Self.normalized(routes)
        self.groupsEnabled = groupsEnabled
    }

    /// Claims a decoded legacy single-link binding. Callers must pass the chat id
    /// from the persisted legacy field and only invoke this for a Telegram
    /// `private` chat; the method refuses every widening or second claim.
    public func claimLegacyPrivateRoute(
        chatID: Int64,
        userID: Int64,
        roomID: String
    ) throws -> TerminalTelegramRouteLease {
        guard routes.isEmpty else { throw TerminalTelegramRouteDenial.unauthorized }
        return try create(
            chatID: chatID, ownerUserID: userID, roomID: roomID, chatKind: .privateChat
        )
    }

    @discardableResult
    public func create(
        chatID: Int64,
        ownerUserID: Int64,
        topicID: Int? = nil,
        roomID: String,
        chatKind: TerminalTelegramChatKind
    ) throws -> TerminalTelegramRouteLease {
        guard chatKind.isPrivate || groupsEnabled else { throw TerminalTelegramRouteDenial.groupsNotEnabled }
        guard let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw TerminalTelegramRouteDenial.noRoute
        }
        var draft = routes
        let nextGeneration = (draft.filter { $0.chatID == chatID && $0.topicID == topicID }
            .map(\.generation).max() ?? 0) + 1
        draft.removeAll { $0.chatID == chatID && $0.topicID == topicID }
        let route = AgentTelegramRouteManifest(
            chatID: chatID, ownerUserID: ownerUserID, topicID: topicID,
            roomID: room, chatKind: chatKind, generation: nextGeneration
        )
        draft.append(route)
        try commit(draft)
        return lease(route, userID: ownerUserID)
    }

    /// Resolves an exact topic first, then the active chat fallback. A deleted or
    /// closed exact route does not resurrect; only a missing/deleted topic may use
    /// fallback, while a closed topic intentionally remains closed.
    public func resolve(
        chatID: Int64,
        userID: Int64,
        topicID: Int?,
        chatKind: TerminalTelegramChatKind
    ) throws -> TerminalTelegramRouteLease {
        guard chatKind.isPrivate || groupsEnabled else { throw TerminalTelegramRouteDenial.groupsNotEnabled }
        let exactMatches = routes.filter { $0.chatID == chatID && $0.topicID == topicID }
        guard exactMatches.count <= 1 else { throw TerminalTelegramRouteDenial.unauthorized }
        let exact = exactMatches.first
        if let exact, exact.lifecycle == .closed { throw TerminalTelegramRouteDenial.routeClosed }
        let candidate: AgentTelegramRouteManifest?
        if let exact, exact.lifecycle == .active {
            candidate = exact
        } else if topicID != nil {
            let fallbacks = routes.filter {
                $0.chatID == chatID && $0.topicID == nil && $0.lifecycle == .active
            }
            guard fallbacks.count <= 1 else { throw TerminalTelegramRouteDenial.unauthorized }
            candidate = fallbacks.first
        } else {
            candidate = nil
        }
        guard let candidate else { throw TerminalTelegramRouteDenial.noRoute }
        guard candidate.chatKind == chatKind, candidate.allows(userID: userID) else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        return lease(candidate, userID: userID, effectiveMessageThreadID: topicID)
    }

    public func close(_ lease: TerminalTelegramRouteLease) throws {
        try mutate(lease) { route in
            AgentTelegramRouteManifest(
                chatID: route.chatID, ownerUserID: route.ownerUserID, topicID: route.topicID,
                roomID: route.roomID, chatKind: route.chatKind,
                memberUserIDs: route.memberUserIDs, lifecycle: .closed,
                generation: route.generation + 1
            )
        }
    }

    public func delete(_ lease: TerminalTelegramRouteLease) throws {
        try mutate(lease) { route in
            AgentTelegramRouteManifest(
                chatID: route.chatID, ownerUserID: route.ownerUserID, topicID: route.topicID,
                roomID: route.roomID, chatKind: route.chatKind,
                memberUserIDs: [], lifecycle: .deleted, generation: route.generation + 1
            )
        }
    }

    public func grant(userID: Int64, on lease: TerminalTelegramRouteLease) throws -> TerminalTelegramRouteLease {
        try mutateReturningLease(lease) { route in
            AgentTelegramRouteManifest(
                chatID: route.chatID, ownerUserID: route.ownerUserID, topicID: route.topicID,
                roomID: route.roomID, chatKind: route.chatKind,
                memberUserIDs: route.memberUserIDs + [userID], lifecycle: route.lifecycle,
                generation: route.generation + 1
            )
        }
    }

    public func revoke(userID: Int64, on lease: TerminalTelegramRouteLease) throws -> TerminalTelegramRouteLease {
        guard userID != routeOwner(for: lease) else { throw TerminalTelegramRouteDenial.ownerCannotBeRevoked }
        return try mutateReturningLease(lease) { route in
            AgentTelegramRouteManifest(
                chatID: route.chatID, ownerUserID: route.ownerUserID, topicID: route.topicID,
                roomID: route.roomID, chatKind: route.chatKind,
                memberUserIDs: route.memberUserIDs.filter { $0 != userID }, lifecycle: route.lifecycle,
                generation: route.generation + 1
            )
        }
    }

    public func validate(_ lease: TerminalTelegramRouteLease) throws {
        guard let route = route(for: lease), route.generation == lease.generation else {
            throw TerminalTelegramRouteDenial.staleGeneration
        }
        guard route.allows(userID: lease.key.userID) else { throw TerminalTelegramRouteDenial.unauthorized }
    }

    private func mutate(
        _ lease: TerminalTelegramRouteLease,
        transform: (AgentTelegramRouteManifest) -> AgentTelegramRouteManifest
    ) throws {
        _ = try mutateReturningLease(lease, transform: transform)
    }

    private func mutateReturningLease(
        _ lease: TerminalTelegramRouteLease,
        transform: (AgentTelegramRouteManifest) -> AgentTelegramRouteManifest
    ) throws -> TerminalTelegramRouteLease {
        guard let index = routes.firstIndex(where: {
            $0.chatID == lease.key.chatID && $0.topicID == lease.key.topicID && $0.roomID == lease.key.roomID
        }), routes[index].generation == lease.generation else {
            throw TerminalTelegramRouteDenial.staleGeneration
        }
        guard routes[index].ownerUserID == lease.key.userID else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        var draft = routes
        draft[index] = transform(draft[index])
        try commit(draft)
        return self.lease(draft[index], userID: lease.key.userID)
    }

    private func routeOwner(for lease: TerminalTelegramRouteLease) -> Int64? {
        route(for: lease)?.ownerUserID
    }

    private func route(for lease: TerminalTelegramRouteLease) -> AgentTelegramRouteManifest? {
        routes.first {
            $0.chatID == lease.key.chatID && $0.topicID == lease.key.topicID && $0.roomID == lease.key.roomID
        }
    }

    private func lease(
        _ route: AgentTelegramRouteManifest,
        userID: Int64,
        effectiveMessageThreadID: Int? = nil
    ) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: TerminalTelegramRouteKey(
                chatID: route.chatID, userID: userID, topicID: route.topicID, roomID: route.roomID
            ),
            generation: route.generation,
            effectiveMessageThreadID: effectiveMessageThreadID ?? route.topicID
        )
    }

    private func commit(_ draft: [AgentTelegramRouteManifest]) throws {
        let normalized = Self.normalized(draft)
        try persist(normalized)
        routes = normalized
    }

    private nonisolated static func normalized(
        _ routes: [AgentTelegramRouteManifest]
    ) -> [AgentTelegramRouteManifest] {
        routes.sorted {
            ($0.chatID, $0.topicID ?? Int.min, $0.roomID) < ($1.chatID, $1.topicID ?? Int.min, $1.roomID)
        }
    }
}
