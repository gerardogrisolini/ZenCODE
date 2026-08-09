//
//  CoreAILocalModelSupport.swift
//  ZenCODE
//
//  Platform-neutral selection and resource-path support for the optional
//  Core AI backend. The implementation is compiled separately below the
//  platform availability boundary; Linux and remote providers do not import
//  FoundationModels or the Apple Core AI package.
//

import Foundation

public enum CoreAILocalModelSupport {
    /// Explicit model identifier for the bundled local Qwen path.
    public static let qwenModelID = "coreai:qwen"

    /// Directory name emitted by the upstream Core AI Qwen3 export examples.
    public static let qwenModelDirectoryName = "Qwen3-0.6B"
    public static let modelsDirectoryName = "models"

    /// Resolves the one supported local model location. The path is intentionally
    /// centralized here so composition roots and tests cannot drift apart.
    public static func qwenResourcesURL(
        fileManager: FileManager = .default
    ) -> URL {
        AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent(modelsDirectoryName, isDirectory: true)
            .appendingPathComponent(qwenModelDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    public static func isLocalModelID(_ modelID: String?) -> Bool {
        guard let modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !modelID.isEmpty else {
            return false
        }
        return modelID.caseInsensitiveCompare(qwenModelID) == .orderedSame
    }
}

public enum CoreAILocalBackendError: LocalizedError, Sendable {
    case unavailableOnCurrentPlatform
    case unsupportedModelID(String)
    case missingResources(URL)
    case invalidResources(URL, String)
    case missingSession(String)
    case concurrentRequest(String)
    case unsupportedAttachments
    case generationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailableOnCurrentPlatform:
            return "The Core AI local backend requires macOS 27 or later."
        case let .unsupportedModelID(modelID):
            return "Unsupported Core AI local model '\(modelID)'. Use '\(CoreAILocalModelSupport.qwenModelID)'."
        case let .missingResources(url):
            return "Core AI model resources were not found at '\(url.path)'. Export Qwen3-0.6B into the ZenCODE support directory at that path."
        case let .invalidResources(url, reason):
            return "Core AI model resources at '\(url.path)' are invalid: \(reason)"
        case let .missingSession(sessionID):
            return "Core AI session '\(sessionID)' does not exist."
        case let .concurrentRequest(sessionID):
            return "Core AI session '\(sessionID)' is already generating a response."
        case .unsupportedAttachments:
            return "The configured Core AI Qwen model does not support image or video attachments."
        case let .generationFailed(reason):
            return "Core AI generation failed: \(reason)"
        }
    }
}

public enum CoreAILocalBackendFactory {
    /// Factory used by both terminal and ACP composition roots. A `coreai:qwen`
    /// configuration is local; every other configuration keeps the existing
    /// remote provider resolution unchanged.
    public static var factory: AgentRuntimeBackendFactory {
        { configuration, mcpRuntime in
            try makeBackend(configuration: configuration, mcpRuntime: mcpRuntime)
        }
    }

    public static func makeBackend(
        configuration: AgentRuntimeConfiguration,
        mcpRuntime: DirectMCPToolRuntime
    ) throws -> any AgentRuntimeBackend {
        guard let modelID = configuration.modelID,
              CoreAILocalModelSupport.isLocalModelID(modelID) else {
            return try AgentCoreBackend.makeRemoteBackend(
                configuration: configuration,
                mcpRuntime: mcpRuntime
            )
        }

        #if os(macOS) && canImport(CoreAILanguageModels) && canImport(FoundationModels)
        guard #available(macOS 27.0, *) else {
            throw CoreAILocalBackendError.unavailableOnCurrentPlatform
        }
        let resourcesURL = CoreAILocalModelSupport.qwenResourcesURL()
        guard FileManager.default.fileExists(atPath: resourcesURL.path) else {
            throw CoreAILocalBackendError.missingResources(resourcesURL)
        }
        let subAgentFactory: DirectSubAgentContextualBackendFactory = { context in
            try makeBackend(
                configuration: configuration.applyingSubAgentBackendContext(context),
                mcpRuntime: mcpRuntime
            )
        }
        return CoreAILanguageModelBackend(
            configuration: configuration,
            resourcesURL: resourcesURL,
            mcpRuntime: mcpRuntime,
            subAgentContextualBackendFactory: subAgentFactory
        )
        #else
        throw CoreAILocalBackendError.unavailableOnCurrentPlatform
        #endif
    }
}
