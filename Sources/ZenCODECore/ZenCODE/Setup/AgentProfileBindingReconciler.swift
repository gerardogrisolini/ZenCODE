//
//  AgentProfileBindingReconciler.swift
//  ZenCODE
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
    /// skills, and read-only policy. Passing the surviving bindings through
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
                tools: agent.tools,
                skills: agent.skills,
                modelBindings: resolvedBindings.bindings.map(\.routingBinding),
                defaultModelBindingID: agent.defaultModelBindingID
            )
        }
    }

    /// Missing profiles are left for the caller that owns profile creation;
    /// invalid profiles propagate their load error and are never overwritten.
    @discardableResult
    static func reconcileStoredAgents(
        with manifest: AgentSettingsManifest,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let agentsURL = AgentProfileStore.agentsManifestURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: agentsURL.path) else {
            return false
        }

        let existingAgents = try AgentProfileStore.loadRequired(fileManager: fileManager)
        let updatedAgents = reconciledAgents(
            existingAgents,
            models: manifest.models
        )
        guard updatedAgents != existingAgents else {
            return false
        }

        // AgentProfileStore.save preserves the manifest's private permissions
        // and performs an atomic SensitiveFilePermissions write.
        try AgentProfileStore.save(updatedAgents, fileManager: fileManager)
        return true
    }
}
