//
//  AgentRuntimeConfigurationProjection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Read-only view of the runtime fields that the CLI configuration
/// (``AgentConfiguration``) and the session identity
/// (``AgentCoreSessionConfiguration``) share when they project themselves onto
/// ``AgentRuntimeConfiguration``.
///
/// The three configuration types intentionally stay distinct: this protocol
/// only removes the duplicated field-by-field mapping, it never merges them
/// into one DTO.
protocol AgentRuntimeConfigurationProjecting {
    var projectedRuntimeModelID: String? { get }
    var projectedRuntimeBearerToken: String? { get }
    var projectedRuntimeWorkingDirectory: URL { get }
    var projectedRuntimeMaxToolRounds: Int { get }
    var projectedRuntimeMaxOutputTokens: Int? { get }
    var projectedRuntimeVerboseLogging: Bool { get }
    var projectedRuntimeAppMode: Bool { get }
}

extension AgentRuntimeConfigurationProjecting {
    /// Projects the common runtime fields onto a backend configuration.
    ///
    /// Normalization and clamping live in ``AgentRuntimeConfiguration``'s
    /// initializer and are deliberately not repeated here. The model-scoped
    /// settings stay caller-supplied so a source that does not own them keeps
    /// the runtime defaults instead of inventing values.
    func projectedRuntimeConfiguration(
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        locksModelToSession: Bool = false,
        toolAuthorizationHandler: AgentToolAuthorizationHandler? = nil
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: projectedRuntimeModelID,
            bearerToken: projectedRuntimeBearerToken,
            workingDirectory: projectedRuntimeWorkingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: projectedRuntimeMaxToolRounds,
            maxOutputTokens: projectedRuntimeMaxOutputTokens,
            verboseLogging: projectedRuntimeVerboseLogging,
            appMode: projectedRuntimeAppMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler
        )
    }
}

extension AgentConfiguration: AgentRuntimeConfigurationProjecting {
    /// The CLI configuration projects the *effective* model id, which already
    /// merges the explicit flag, the agent profile, and the settings manifest.
    var projectedRuntimeModelID: String? { effectiveModelID }
    var projectedRuntimeBearerToken: String? { bearerToken }
    var projectedRuntimeWorkingDirectory: URL { workingDirectory }
    var projectedRuntimeMaxToolRounds: Int { maxToolRounds }
    var projectedRuntimeMaxOutputTokens: Int? { maxOutputTokens }
    var projectedRuntimeVerboseLogging: Bool { verboseLogging }
    var projectedRuntimeAppMode: Bool { appMode }
}

extension AgentCoreSessionConfiguration: AgentRuntimeConfigurationProjecting {
    var projectedRuntimeModelID: String? { modelID }
    var projectedRuntimeBearerToken: String? { bearerToken }
    var projectedRuntimeWorkingDirectory: URL { workingDirectory }
    var projectedRuntimeMaxToolRounds: Int { maxToolRounds }
    var projectedRuntimeMaxOutputTokens: Int? { maxOutputTokens }
    var projectedRuntimeVerboseLogging: Bool { verboseLogging }
    var projectedRuntimeAppMode: Bool { appMode }
}
