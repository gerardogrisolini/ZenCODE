//
//  LeasedSessionRuntimeBackend.swift
//  ZenCODE
//
//  The session table the direct-tool clients share: sessions by id, each
//  with the generation of its installed incarnation, the leases that fence
//  work to one incarnation, and the session-scoped lookups built on them.
//

import Foundation

/// A lease on one installed incarnation of a client's session: a session
/// replaced or closed after the lease was taken is no longer reached through
/// it, even when a new session reuses the id.
struct RuntimeSessionLease: Sendable {
    let id: String
    let generation: UInt64
}

/// What the shared session code reads of a client's session.
protocol LeasedRuntimeSession {
    var id: String { get }
    /// The folder the session works in.
    var workingDirectoryURL: URL { get }
    var allowedToolNames: Set<String>? { get set }
}

/// A direct-tool backend that keeps its sessions by id with the generation of
/// each installed incarnation. Installing and invalidating a session stay
/// with each client, which updates `sessionGenerations` there; this adapter
/// owns the leases, the leased reads and mutations, and the lookups that do
/// not depend on the provider.
protocol LeasedSessionRuntimeBackend: DirectToolRuntimeBackend {
    associatedtype Session: LeasedRuntimeSession

    var sessions: [String: Session] { get set }
    /// The generation of each session id's installed incarnation, advanced at
    /// every install and invalidation.
    var sessionGenerations: [String: UInt64] { get }

    /// Called after ``mutateSession(for:_:)`` changed the session `id`.
    func sessionDidMutate(id: String)
}

extension LeasedSessionRuntimeBackend {
    typealias SessionLease = RuntimeSessionLease

    func sessionDidMutate(id _: String) {}

    func sessionLease(for id: String) -> SessionLease? {
        guard sessions[id] != nil, let generation = sessionGenerations[id] else {
            return nil
        }
        return SessionLease(id: id, generation: generation)
    }

    func currentSession(for lease: SessionLease) -> Session? {
        guard sessionGenerations[lease.id] == lease.generation else {
            return nil
        }
        return sessions[lease.id]
    }

    /// Applies `mutation` to the session of `lease`; `false`, and nothing
    /// changed, when that incarnation is gone.
    @discardableResult
    func mutateSession(
        for lease: SessionLease,
        _ mutation: (inout Session) -> Void
    ) -> Bool {
        guard sessionGenerations[lease.id] == lease.generation,
              var session = sessions[lease.id] else {
            return false
        }
        mutation(&session)
        sessions[lease.id] = session
        sessionDidMutate(id: lease.id)
        return true
    }

    public func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String? = nil,
        history: [AgentRuntimeMessage] = [],
        cacheKey: String? = nil,
        allowedToolNames: Set<String>? = nil,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        guard sessions[id] == nil else {
            return
        }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public func activeToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        await toolDescriptors(sessionID: sessionID, discoversFeatureTools: true)
    }

    public func knownToolDescriptors(
        sessionID: String?
    ) async -> [DirectToolDescriptor] {
        await toolDescriptors(sessionID: sessionID, discoversFeatureTools: false)
    }

    /// The descriptors of the session `sessionID`, else of any session; none
    /// without a session.
    private func toolDescriptors(
        sessionID: String?,
        discoversFeatureTools: Bool
    ) async -> [DirectToolDescriptor] {
        let session = if let sessionID {
            sessions[sessionID]
        } else {
            sessions.values.first
        }
        guard let session else {
            return []
        }
        return await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.workingDirectoryURL,
            sessionID: session.id,
            discoversFeatureTools: discoversFeatureTools
        )
    }
}
