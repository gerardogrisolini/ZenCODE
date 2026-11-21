//
//  AgentProfileBindingReconciler.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Reconciles persisted agent bindings with the model catalog assembled by setup.
//

import Foundation

/// Keeps agent profiles aligned with the model manifest about to be persisted.
///
/// Reconciliation intentionally uses `AgentDelegationCatalog`, the same
/// provider-aware resolver used by delegation routing. The manifest is
/// authoritative even when it contains zero models.
enum AgentProfileBindingReconciler {
    /// Removes only bindings that no longer resolve uniquely in `models`.
    ///
    /// The profile reconstruction preserves its identity, instructions, tools,
    /// skills, read-only policy, and role. Passing the surviving bindings through
    /// `AgentProfile` also applies its stable default-binding invariant: a
    /// retained default stays selected; otherwise the first normalized binding
    /// becomes the default deterministically.
    static func reconciledAgents(
        _ agents: [AgentProfile],
        models: [AgentSettingsModelManifest]
    ) -> [AgentProfile] {
        return agents.map { agent in
            let resolvedBindings = AgentDelegationCatalog.resolvedBindings(
                for: agent,
                snapshot: .available(models: models)
            )

            return AgentProfile(
                id: agent.id,
                name: agent.name,
                instructions: agent.instructions,
                symbolName: agent.symbolName,
                readOnly: agent.readOnly,
                role: agent.role,
                tools: agent.tools,
                skills: agent.skills,
                modelBindings: resolvedBindings.bindings.map(\.routingBinding),
                defaultModelBindingID: agent.defaultModelBindingID
            )
        }
    }
}
