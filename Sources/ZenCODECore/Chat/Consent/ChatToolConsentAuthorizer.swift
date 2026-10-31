//
//  ChatToolConsentAuthorizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Channel-neutral consent policy for gated tool calls.
///
/// The authorizer owns everything about consent that does not depend on the
/// transport: which tools are gated, the consent cache key, in-memory
/// "always" decisions scoped to the owning session, persisted `local.exec`
/// approvals, dialog serialization, and teardown invalidation. The operator
/// interaction itself is delegated to a ``ChatInteractionHost`` (terminal
/// card, ACP `session/request_permission`, a headless host that offers none).
///
/// Every outcome other than an explicit approval is a refusal: callers must
/// never treat `unavailable` or `cancelled` as consent.
public actor ChatToolConsentAuthorizer {
    /// Detailed result of one authorization. Surfaces that race several
    /// consent channels (terminal and Telegram) must distinguish an explicit
    /// rejection from a channel that is unavailable or was cancelled.
    public enum AuthorizationOutcome: Sendable, Equatable {
        case allowedOnce
        case allowedAlways
        case denied
        case unavailable
        case cancelled

        public var isApproved: Bool {
            switch self {
            case .allowedOnce, .allowedAlways:
                true
            case .denied, .unavailable, .cancelled:
                false
            }
        }
    }

    private struct DialogWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    /// Tool names this authorizer gates: shell commands plus the destructive
    /// direct tools. Everything else is pre-approved by tool selection.
    public static let gatedToolNames: Set<String> =
        DirectToolExecutor.destructiveGatedToolNames.union(["local.exec"])

    private let host: any ChatInteractionHost
    private var alwaysAllowedKeys = Set<String>()
    private var alwaysRejectedKeys = Set<String>()
    private var decisionKeysBySessionID: [String: Set<String>] = [:]
    private var sessionGenerations: [String: UInt64] = [:]
    private var generation: UInt64 = 0
    private var isDialogActive = false
    private var dialogWaiters: [DialogWaiter] = []
    private var cancelledDialogWaiterIDs = Set<UUID>()

    public init(host: any ChatInteractionHost) {
        self.host = host
    }

    // MARK: - Authorization

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        await authorizationOutcome(for: request).isApproved
    }

    public func authorizationOutcome(
        for request: AgentToolAuthorizationRequest
    ) async -> AuthorizationOutcome {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return .allowedOnce
        }

        let ownerSessionID = Self.ownerSessionID(for: request)
        let sessionGeneration = sessionGenerations[ownerSessionID, default: 0]
        let currentGeneration = generation
        let cacheKey = Self.permissionCacheKeyValue(for: request)
        if let cached = cachedOutcome(for: request, cacheKey: cacheKey) {
            return cached
        }

        let capabilities = host.capabilities
        guard capabilities.contains(.toolConsent) else {
            // A host that cannot ask the operator never receives a request:
            // the gated call is refused with an actionable diagnostic.
            AgentOutput.standardError.writeString(
                LocalExecPermissionAuthorizer.nonInteractiveConsentMessage(for: request)
            )
            return .unavailable
        }

        // Actor isolation alone does not serialize this method across the host
        // call: the actor is re-entrant while the operator's answer is awaited.
        // Hosts sharing one input surface (the terminal) explicitly queue
        // dialogs so concurrent tool calls can never install multiple readers
        // on the same TTY or fight over panel focus.
        var holdsDialogSlot = false
        defer {
            if holdsDialogSlot {
                releaseDialogSlot()
            }
        }
        if capabilities.contains(.serialConsentDialogs) {
            guard await acquireDialogSlot() else {
                return Task.isCancelled ? .cancelled : .unavailable
            }
            holdsDialogSlot = true
            guard !Task.isCancelled else {
                return .cancelled
            }

            // A request ahead of us may have chosen Always while this request
            // was queued, so avoid presenting a now-redundant dialog.
            if let cached = cachedOutcome(for: request, cacheKey: cacheKey) {
                return cached
            }
            // Teardown while queued must not surface a dialog for a gone session.
            guard isCurrent(
                ownerSessionID: ownerSessionID,
                sessionGeneration: sessionGeneration,
                generation: currentGeneration
            ) else {
                return .cancelled
            }
        }

        guard let decision = await host.requestToolConsent(request) else {
            return Task.isCancelled ? .cancelled : .unavailable
        }

        // Reentrancy during the dialog must not resurrect consent after teardown.
        guard !Task.isCancelled,
              isCurrent(
                ownerSessionID: ownerSessionID,
                sessionGeneration: sessionGeneration,
                generation: currentGeneration
              ) else {
            return .cancelled
        }

        switch decision {
        case .allowOnce:
            return .allowedOnce
        case .allowAlways:
            alwaysAllowedKeys.insert(cacheKey)
            remember(cacheKey: cacheKey, for: ownerSessionID)
            // Only shell command identities are persisted across sessions;
            // every other approval lives in memory for the owning session.
            if request.toolName == "local.exec" {
                LocalExecPermissionAuthorizer.persistAllowedCommand(request.command)
            }
            return .allowedAlways
        case .denyOnce:
            return .denied
        case .denyAlways:
            alwaysRejectedKeys.insert(cacheKey)
            remember(cacheKey: cacheKey, for: ownerSessionID)
            return .denied
        }
    }

    /// Authorizes a request without ever involving the host.
    ///
    /// Headless callers must retain cached and persisted approvals plus
    /// pre-approved tools, but a new gated request has no operator available to
    /// answer: it is refused with an actionable diagnostic.
    public func nonInteractiveOutcome(
        for request: AgentToolAuthorizationRequest
    ) -> AuthorizationOutcome {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return .allowedOnce
        }
        if let cached = cachedOutcome(
            for: request,
            cacheKey: Self.permissionCacheKeyValue(for: request)
        ) {
            return cached
        }
        AgentOutput.standardError.writeString(
            LocalExecPermissionAuthorizer.nonInteractiveConsentMessage(for: request)
        )
        return .unavailable
    }

    /// Returns `true` when this request needs no dialog and is approved: either
    /// the tool is not gated, or a previous approval already covers it.
    ///
    /// Surfaces that mirror the session elsewhere (Telegram) use this to avoid
    /// announcing a consent step that will never be presented. A remembered
    /// rejection is deliberately not "already authorized".
    public func isAlreadyAuthorized(_ request: AgentToolAuthorizationRequest) -> Bool {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return true
        }
        return cachedOutcome(
            for: request,
            cacheKey: Self.permissionCacheKeyValue(for: request)
        )?.isApproved == true
    }

    /// Imports an "always" decision made on another consent surface into this
    /// authorizer. This keeps later turns consistent even if the other surface
    /// (for example Telegram) is disabled after the decision.
    public func recordAlwaysDecision(for request: AgentToolAuthorizationRequest) {
        guard Self.gatedToolNames.contains(request.toolName) else {
            return
        }
        let cacheKey = Self.permissionCacheKeyValue(for: request)
        alwaysAllowedKeys.insert(cacheKey)
        remember(cacheKey: cacheKey, for: Self.ownerSessionID(for: request))
        if request.toolName == "local.exec" {
            LocalExecPermissionAuthorizer.persistAllowedCommand(request.command)
        }
    }

    // MARK: - Cache lifecycle

    /// Drops the in-memory decisions owned by one session and invalidates its
    /// dialogs that are still awaiting an answer.
    public func removeCachedDecisions(sessionID: String) {
        sessionGenerations[sessionID, default: 0] &+= 1
        guard let keys = decisionKeysBySessionID.removeValue(forKey: sessionID) else {
            return
        }
        alwaysAllowedKeys.subtract(keys)
        alwaysRejectedKeys.subtract(keys)
    }

    /// Drops every in-memory decision and invalidates all dialogs that are
    /// still awaiting an answer.
    public func removeAllCachedDecisions() {
        generation &+= 1
        sessionGenerations.removeAll()
        alwaysAllowedKeys.removeAll()
        alwaysRejectedKeys.removeAll()
        decisionKeysBySessionID.removeAll()
    }

    /// Drops process-local authorization state so a completed setup run is
    /// reconciled from the current permissions manifest. This is especially
    /// important after setup reset removes that manifest.
    public func reloadPersistedPermissions() {
        removeAllCachedDecisions()
    }

    func cachedDecisionCount(sessionID: String) -> Int {
        decisionKeysBySessionID[sessionID]?.count ?? 0
    }

    // MARK: - Cache keys

    static func permissionCacheKeyValue(for request: AgentToolAuthorizationRequest) -> String {
        let components = [
            request.sessionID ?? "",
            request.toolName,
            request.workingDirectory,
            permissionCacheCommandIdentity(for: request)
        ]
        guard let identity = request.delegatedIdentity else {
            return lengthPrefixedComponents(components)
        }
        return lengthPrefixedComponents(components + [identity.rootSessionID, identity.agentID])
    }

    static func permissionCacheCommandIdentity(
        for request: AgentToolAuthorizationRequest
    ) -> String {
        guard request.toolName == "local.exec" else {
            return request.command
        }
        let identities = LocalExecPermissionAuthorizer
            .localExecPermissionCacheIdentities(for: request.command)
        guard !identities.isEmpty else {
            return request.command
        }
        return lengthPrefixedComponents(identities)
    }

    private static func lengthPrefixedComponents(_ components: [String]) -> String {
        "\(components.count):" + components.map {
            "\($0.utf8.count):\($0)"
        }.joined()
    }

    private static func ownerSessionID(for request: AgentToolAuthorizationRequest) -> String {
        request.delegatedIdentity?.rootSessionID ?? request.sessionID ?? ""
    }

    // MARK: - Decision bookkeeping

    private func cachedOutcome(
        for request: AgentToolAuthorizationRequest,
        cacheKey: String
    ) -> AuthorizationOutcome? {
        if alwaysAllowedKeys.contains(cacheKey) {
            return .allowedAlways
        }
        if alwaysRejectedKeys.contains(cacheKey) {
            return .denied
        }
        if request.toolName == "local.exec",
           LocalExecPermissionAuthorizer.isCommandPersistentlyAllowed(request.command) {
            return .allowedAlways
        }
        return nil
    }

    private func isCurrent(
        ownerSessionID: String,
        sessionGeneration: UInt64,
        generation currentGeneration: UInt64
    ) -> Bool {
        generation == currentGeneration
            && sessionGenerations[ownerSessionID, default: 0] == sessionGeneration
    }

    private func remember(cacheKey: String, for rawSessionID: String) {
        guard let sessionID = rawSessionID.nilIfBlank else { return }
        decisionKeysBySessionID[sessionID, default: []].insert(cacheKey)
    }

    // MARK: - Dialog queue

    private func acquireDialogSlot() async -> Bool {
        guard !Task.isCancelled else {
            return false
        }
        guard isDialogActive else {
            isDialogActive = true
            return true
        }

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancelledDialogWaiterIDs.remove(waiterID) != nil {
                    continuation.resume(returning: false)
                } else {
                    dialogWaiters.append(
                        DialogWaiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task(name: "tool consent dialog cancellation") {
                await self.cancelDialogWaiter(id: waiterID)
            }
        }

        guard acquired, !Task.isCancelled else {
            cancelledDialogWaiterIDs.remove(waiterID)
            if acquired {
                // Ownership may already have been handed to this waiter just as
                // it was cancelled; pass the slot on instead of stranding it.
                releaseDialogSlot()
            }
            return false
        }
        return true
    }

    private func releaseDialogSlot() {
        guard !dialogWaiters.isEmpty else {
            isDialogActive = false
            return
        }
        dialogWaiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelDialogWaiter(id: UUID) {
        if let index = dialogWaiters.firstIndex(where: { $0.id == id }) {
            dialogWaiters.remove(at: index).continuation.resume(returning: false)
        } else {
            // Cancellation can race ahead of continuation registration.
            cancelledDialogWaiterIDs.insert(id)
        }
    }
}
