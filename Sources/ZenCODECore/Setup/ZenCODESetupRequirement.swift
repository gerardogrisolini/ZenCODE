//
//  ZenCODESetupRequirement.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//


/// Shared startup gate for the executable composition root. A decodable
/// manifest is not sufficient by itself: the runtime also needs at least one
/// model and the remaining required support files must be ready.
public enum ZenCODESetupRequirement {
    public static func isRequired(
        manifest: AgentSettingsManifest?,
        status: SetupStatus
    ) -> Bool {
        manifest?.models.isEmpty != false || status.requiresSetup
    }

    /// Evaluates the gate against the persisted configuration of this process:
    /// the same rule the executable applies before it launches the chat.
    static func isRequired() -> Bool {
        let manifest = try? AgentSettingsManifestStore.loadRequired(
            from: AgentSettingsManifestStore.settingsURL()
        )
        return isRequired(manifest: manifest, status: ZenInspector.status())
    }
}
