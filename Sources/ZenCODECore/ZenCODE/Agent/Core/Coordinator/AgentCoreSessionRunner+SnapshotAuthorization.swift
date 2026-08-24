//
//  AgentCoreSessionRunner+SnapshotAuthorization.swift
//  ZenCODE
//

import Foundation
import Synchronization
import ToolCore


extension AgentCoreSessionRunner {
    func recoveredSessionSnapshot(
        backend: AgentCoreBackend,
        configuration: AgentCoreSessionConfiguration,
        recorder: AgentCorePromptTurnRecorder,
        sessionGeneration: SessionGeneration?
    ) async -> AgentCoreSessionSnapshotRecovery {
        let recordedSnapshot = await recorder.snapshot()
        if let backendSnapshot = await backend.snapshotSession(id: configuration.sessionID),
           backendSnapshot.includesLikelyTurn(from: recordedSnapshot) {
            cacheSessionSnapshot(
                backendSnapshot,
                baseConfiguration: configuration,
                sessionGeneration: sessionGeneration
            )
            return AgentCoreSessionSnapshotRecovery(
                snapshot: backendSnapshot,
                shouldRestoreBackend: false
            )
        }

        cacheSessionSnapshot(
            recordedSnapshot,
            baseConfiguration: configuration,
            sessionGeneration: sessionGeneration
        )
        return AgentCoreSessionSnapshotRecovery(
            snapshot: recordedSnapshot,
            shouldRestoreBackend: isCurrentSessionGeneration(
                sessionGeneration,
                for: configuration.sessionID
            )
        )
    }

    func restoreSessionIfNeeded(
        _ recovery: AgentCoreSessionSnapshotRecovery,
        backend: AgentCoreBackend,
        baseConfiguration: AgentCoreSessionConfiguration,
        sessionGeneration: SessionGeneration?
    ) async {
        guard recovery.shouldRestoreBackend else {
            return
        }
        // The session may have been closed or rebuilt while the turn was
        // running; recreating it here would resurrect discarded state.
        guard isCurrentSessionGeneration(
            sessionGeneration,
            for: baseConfiguration.sessionID
        ) else {
            return
        }
        let configuration = baseConfiguration.replacingRuntimeState(
            with: recovery.snapshot
        )
        await createBackendSession(backend, configuration: configuration)
    }

    private func cacheSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot,
        baseConfiguration: AgentCoreSessionConfiguration,
        sessionGeneration: SessionGeneration?
    ) {
        snapshotStore.cache(
            snapshot,
            baseConfiguration: baseConfiguration,
            generation: sessionGeneration
        )
    }

    func compactStoredSession(
        id sessionID: String,
        force: Bool,
        maxTokensOverride: Int?
    ) -> AgentRuntimeSessionCompactionResult? {
        let baseConfiguration: AgentCoreSessionConfiguration
        let currentSnapshot: AgentRuntimeSessionSnapshot
        if let snapshot = lastKnownSessionSnapshots[sessionID],
           let configuration = sessions[sessionID] {
            baseConfiguration = configuration
            currentSnapshot = snapshot
        } else if let configuration = sessions[sessionID] {
            baseConfiguration = configuration
            currentSnapshot = AgentRuntimeSessionSnapshot(configuration: configuration)
        } else {
            return nil
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            currentSnapshot.compactionInputMessages,
            budget: AgentConversationCompactionBudget(
                contextWindowTokens: maxTokensOverride ?? baseConfiguration.configuredContextWindowLimit,
                maxOutputTokens: baseConfiguration.maxOutputTokens
            ),
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        return AgentRuntimeSessionCompactionResult(
            snapshot: currentSnapshot.applyingCompaction(result),
            compactionResult: result
        )
    }

    func cacheCompactedSessionSnapshot(
        _ snapshot: AgentRuntimeSessionSnapshot
    ) {
        snapshotStore.cacheCompacted(snapshot)
    }

    func authorizeTool(_ request: AgentToolAuthorizationRequest) async -> Bool {
        // Full access skips prompts for shell commands and for the destructive
        // direct tools alike; otherwise gating deletes while allowing `rm -rf`
        // through local.exec would only push callers toward the shell.
        if authorizationRouter.localExecAccessMode == .fullAccess,
           LocalExecPermissionAuthorizer.gatedToolNames.contains(request.toolName) {
            return true
        }

        // Delegated sub-agents are not bound to the turn that spawned them:
        // they call tools from their own private session and keep working after
        // that turn returned, so the turn/session match below can never hold
        // for them. Route on the runtime-minted delegation identity instead,
        // and only when its root session is one this runner actually owns — an
        // unknown root session names no operator, so there is nobody to ask.
        // The handler is still never picked arbitrarily from the Dictionary: it
        // is the one registered for that exact root session, or the runner's
        // default. With neither, the request fails closed like any other.
        if let delegation = request.delegatedIdentity {
            guard isKnownSession(delegation.rootSessionID),
                  let handler = authorizationRouter.handler(forSessionID: delegation.rootSessionID)
                      ?? defaultToolAuthorizationHandler else {
                return false
            }
            let presentedRequest = await delegatedRequestForPresentation(
                request,
                delegation: delegation
            )
            return await handler(presentedRequest)
        }

        // A request must name the exact live turn and session. Never select an
        // arbitrary handler from a Dictionary: concurrent prompts in the same
        // session can have different authorization policies.
        guard let turnID = request.turnID,
              let sessionID = request.sessionID,
              let handler = authorizationRouter.handler(
                forPromptID: turnID,
                sessionID: sessionID
              ) else {
            return false
        }
        return await handler(request)
    }

    /// A session this runner owns, either because it is still configured or
    /// because a turn of it registered an operator handler. Anything else is
    /// not ours to authorize.
    private func isKnownSession(_ sessionID: String) -> Bool {
        sessions[sessionID] != nil || authorizationRouter.knows(sessionID: sessionID)
    }

    /// Names the delegated agent in the title so the operator can see *who* is
    /// asking before approving.
    ///
    /// Strictly best-effort: resolution never gates the decision, and a missing
    /// backend, an unknown id, or a blank name falls back to the agent id. Only
    /// `title` changes — `LocalExecPermissionAuthorizer` keys its consent cache
    /// on tool name and command — so remembered approvals stay keyed exactly as
    /// before. The single `await` here reads the backend's sub-agent registry,
    /// which never calls back into this runner, so it cannot stall a
    /// coordinator turn waiting on this actor.
    private func delegatedRequestForPresentation(
        _ request: AgentToolAuthorizationRequest,
        delegation: AgentToolAuthorizationRequest.DelegatedIdentity
    ) async -> AgentToolAuthorizationRequest {
        var label = delegation.agentID
        if let backend {
            let snapshots = await backend.subAgentSnapshots()
            if let name = snapshots.first(where: { $0.id == delegation.agentID })?.name.nilIfBlank {
                label = name
            }
        }
        return request.withTitle("[agent \(label)] \(request.title)")
    }
}
