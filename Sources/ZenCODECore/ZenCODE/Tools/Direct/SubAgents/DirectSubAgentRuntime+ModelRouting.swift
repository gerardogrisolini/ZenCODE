//
//  DirectSubAgentRuntime+ModelRouting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Supplies one authoritative model-catalog snapshot for an `agent.create`
/// batch. The snapshot includes provider configuration and credentials needed to
/// create the child backend without a later global model lookup.
public typealias DirectSubAgentModelCatalogProvider = @Sendable () -> AgentDelegationCatalogSnapshot

extension DirectSubAgentRuntime {
    public static func liveModelCatalogProvider() -> AgentDelegationCatalogSnapshot {
        AgentDelegationCatalog.liveSnapshot()
    }

    /// Resolves and authorizes the explicit model reference within the profile's
    /// delegatable bindings and one catalog snapshot.
    ///
    /// This runs before reservations and task claims. The returned payload owns
    /// the canonical binding and resolved provider selection that backend
    /// creation must use; no second profile or global catalog lookup occurs.
    public static func resolvingModelBinding(
        for payload: RequestedAgentPayload,
        profile: AgentProfile,
        snapshot: AgentDelegationCatalogSnapshot
    ) throws -> RequestedAgentPayload {
        guard !profile.modelBindings.isEmpty else {
            if let requestedModelID = payload.requestedModelID {
                throw DirectSubAgentRuntimeError.modelNotAllowedForProfile(
                    modelID: requestedModelID,
                    profile: profile.displayName
                )
            }
            return payload
        }

        guard let requestedModelID = payload.requestedModelID else {
            throw DirectSubAgentRuntimeError.missingArgument("model")
        }
        let resolved = AgentDelegationCatalog.resolvedBindings(
            for: profile,
            snapshot: snapshot
        )

        switch resolved.selection(for: requestedModelID) {
        case let .selected(binding):
            guard let modelSelection = snapshot.modelSelection(for: binding) else {
                throw DirectSubAgentRuntimeError.modelBindingUnavailable(
                    modelID: requestedModelID,
                    profile: profile.displayName,
                    reason: "the resolved provider configuration is incomplete"
                )
            }
            return payload.applying(
                modelBinding: binding.routingBinding,
                modelSelection: modelSelection
            )

        case let .ambiguous(candidates):
            throw DirectSubAgentRuntimeError.ambiguousModelReference(
                modelID: requestedModelID,
                profile: profile.displayName,
                candidates: candidates
            )

        case let .unavailable(stale):
            throw DirectSubAgentRuntimeError.modelBindingUnavailable(
                modelID: requestedModelID,
                profile: profile.displayName,
                reason: stale.diagnostic
            )

        case .notAuthorized, .unconstrained:
            throw DirectSubAgentRuntimeError.modelNotAllowedForProfile(
                modelID: requestedModelID,
                profile: profile.displayName
            )
        }
    }
}
