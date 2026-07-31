//
//  ZenCODESetupRequirement.swift
//  ZenCODE
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
}
