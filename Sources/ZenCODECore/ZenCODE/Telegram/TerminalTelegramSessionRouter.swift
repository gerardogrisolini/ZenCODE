//
//  TerminalTelegramSessionRouter.swift
//  ZenCODE
//

import Foundation
import Synchronization
import ToolCore

/// Stable identity of one Telegram-to-ZenCODE session route.
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

/// Telegram wire chat classification. Routing accepts only `privateChat`; every
/// other wire value is collapsed to `unsupported` and rejected before any work.
public enum TerminalTelegramChatKind: Codable, Equatable, Sendable {
    case privateChat
    case unsupported

    private static let privateWireValue = "private"

    init(wireValue: String) {
        self = wireValue == Self.privateWireValue ? .privateChat : .unsupported
    }

    public init(from decoder: Decoder) throws {
        self.init(wireValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .privateChat ? Self.privateWireValue : "unsupported")
    }
}

public enum TerminalTelegramRouteLifecycle: String, Codable, Sendable {
    case active
    case closed
    case deleted
}

/// Canonical routing-v2 route. Chat and owner identity are global settings and
/// therefore cannot diverge between personal sessions.
public struct AgentTelegramRouteManifest: Codable, Equatable, Sendable {
    public let topicID: Int?
    public let roomID: String
    public let lifecycle: TerminalTelegramRouteLifecycle
    public let generation: UInt64

    public init(
        topicID: Int? = nil,
        roomID: String,
        lifecycle: TerminalTelegramRouteLifecycle = .active,
        generation: UInt64 = 1
    ) {
        self.topicID = topicID
        self.roomID = roomID
        self.lifecycle = lifecycle
        self.generation = max(1, generation)
    }
}

public struct TerminalTelegramRouteLease: Hashable, Sendable {
    public let key: TerminalTelegramRouteKey
    public let generation: UInt64
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

    public func invalidate() { isCurrent.withLock { $0 = false } }

    public func validate(chatID: Int64, topicID: Int?) async throws {
        guard isCurrent.withLock({ $0 }),
              lease.key.chatID == chatID,
              lease.effectiveMessageThreadID == topicID else { throw CancellationError() }
        try await validateLease(lease)
        guard isCurrent.withLock({ $0 }), !Task.isCancelled else { throw CancellationError() }
    }

    public func validate(chatID: Int64) async throws {
        try await validate(chatID: chatID, topicID: lease.effectiveMessageThreadID)
    }
}

public enum TerminalTelegramRouteDenial: Error, Equatable, Sendable {
    case noRoute
    case routeClosed
    case unauthorized
    case staleGeneration
}

/// Actor-serialized authority for one globally paired private chat owner and
/// that owner's personal session routes.
public actor TerminalTelegramSessionRouter {
    public typealias Persist = @Sendable (Int64, [AgentTelegramRouteManifest]) throws -> Void

    private var linkedChatID: Int64?
    private var ownerUserID: Int64?
    private var routes: [AgentTelegramRouteManifest]
    private let persist: Persist

    public init(
        linkedChatID: Int64? = nil,
        ownerUserID: Int64? = nil,
        routes: [AgentTelegramRouteManifest] = [],
        persist: @escaping Persist = { _, _ in }
    ) {
        self.linkedChatID = linkedChatID
        self.ownerUserID = ownerUserID
        self.routes = Self.validated(routes) ?? []
        self.persist = persist
    }

    public func snapshot() -> [AgentTelegramRouteManifest] { routes }

    public func refresh(
        linkedChatID: Int64?,
        ownerUserID: Int64?,
        routes: [AgentTelegramRouteManifest]
    ) {
        self.linkedChatID = linkedChatID
        self.ownerUserID = ownerUserID
        self.routes = Self.validated(routes) ?? []
    }

    @discardableResult
    public func create(topicID: Int? = nil, roomID: String) throws -> TerminalTelegramRouteLease {
        guard let chatID = linkedChatID, let userID = ownerUserID else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        guard let room = roomID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            throw TerminalTelegramRouteDenial.noRoute
        }
        var draft = routes
        let nextGeneration = (draft.filter { $0.topicID == topicID }.map(\.generation).max() ?? 0) + 1
        draft.removeAll { $0.topicID == topicID }
        let route = AgentTelegramRouteManifest(topicID: topicID, roomID: room, generation: nextGeneration)
        draft.append(route)
        try commit(draft)
        return lease(route, chatID: chatID, userID: userID)
    }

    public func resolve(chatID: Int64, userID: Int64, topicID: Int?) throws -> TerminalTelegramRouteLease {
        guard linkedChatID == chatID, ownerUserID == userID else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        let exactMatches = routes.filter { $0.topicID == topicID }
        guard exactMatches.count <= 1 else { throw TerminalTelegramRouteDenial.unauthorized }
        let exact = exactMatches.first
        if let exact, exact.lifecycle == .closed { throw TerminalTelegramRouteDenial.routeClosed }
        let candidate: AgentTelegramRouteManifest?
        if let exact, exact.lifecycle == .active {
            candidate = exact
        } else if topicID != nil {
            let fallbacks = routes.filter { $0.topicID == nil && $0.lifecycle == .active }
            guard fallbacks.count <= 1 else { throw TerminalTelegramRouteDenial.unauthorized }
            candidate = fallbacks.first
        } else {
            candidate = nil
        }
        guard let candidate else { throw TerminalTelegramRouteDenial.noRoute }
        return lease(candidate, chatID: chatID, userID: userID, effectiveMessageThreadID: topicID)
    }

    public func close(_ lease: TerminalTelegramRouteLease) throws {
        try mutate(lease) { route in
            AgentTelegramRouteManifest(topicID: route.topicID, roomID: route.roomID,
                lifecycle: .closed, generation: route.generation + 1)
        }
    }

    public func delete(_ lease: TerminalTelegramRouteLease) throws {
        try mutate(lease) { route in
            AgentTelegramRouteManifest(topicID: route.topicID, roomID: route.roomID,
                lifecycle: .deleted, generation: route.generation + 1)
        }
    }

    public func validate(_ lease: TerminalTelegramRouteLease) throws {
        guard linkedChatID == lease.key.chatID, ownerUserID == lease.key.userID else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        guard let route = uniqueRoute(for: lease), route.generation == lease.generation else {
            throw TerminalTelegramRouteDenial.staleGeneration
        }
        guard route.lifecycle == .active else { throw TerminalTelegramRouteDenial.unauthorized }
    }

    private func mutate(
        _ lease: TerminalTelegramRouteLease,
        transform: (AgentTelegramRouteManifest) -> AgentTelegramRouteManifest
    ) throws {
        guard linkedChatID == lease.key.chatID, ownerUserID == lease.key.userID else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        let indices = routes.indices.filter {
            routes[$0].topicID == lease.key.topicID && routes[$0].roomID == lease.key.roomID
        }
        guard indices.count == 1, let index = indices.first,
              routes[index].generation == lease.generation else {
            throw TerminalTelegramRouteDenial.staleGeneration
        }
        var draft = routes
        draft[index] = transform(draft[index])
        try commit(draft)
    }

    private func uniqueRoute(for lease: TerminalTelegramRouteLease) -> AgentTelegramRouteManifest? {
        let matches = routes.filter { $0.topicID == lease.key.topicID && $0.roomID == lease.key.roomID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func lease(
        _ route: AgentTelegramRouteManifest,
        chatID: Int64,
        userID: Int64,
        effectiveMessageThreadID: Int? = nil
    ) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: TerminalTelegramRouteKey(chatID: chatID, userID: userID,
                topicID: route.topicID, roomID: route.roomID),
            generation: route.generation,
            effectiveMessageThreadID: effectiveMessageThreadID ?? route.topicID
        )
    }

    private func commit(_ draft: [AgentTelegramRouteManifest]) throws {
        guard let normalized = Self.validated(draft) else {
            throw TerminalTelegramRouteDenial.unauthorized
        }
        guard let ownerUserID else { throw TerminalTelegramRouteDenial.unauthorized }
        try persist(ownerUserID, normalized)
        routes = normalized
    }

    private nonisolated static func validated(
        _ routes: [AgentTelegramRouteManifest]
    ) -> [AgentTelegramRouteManifest]? {
        var topics = Set<Int?>()
        for route in routes {
            guard route.roomID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil,
                  topics.insert(route.topicID).inserted else { return nil }
        }
        return routes.sorted { ($0.topicID ?? Int.min, $0.roomID) < ($1.topicID ?? Int.min, $1.roomID) }
    }
}
