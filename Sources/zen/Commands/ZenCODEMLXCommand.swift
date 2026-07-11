//
//  ZenCODEMLXCommand.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 13/06/26.
//

import Foundation
import ZenCODECore
import ZenPackageMetadata

#if ZENCODE_LOCAL_MLX
import MLXServerCore

enum ZenCODEMLXCommand {
    static let option = "--mlx"

    @MainActor
    static func run(arguments rawArguments: [String]) async throws {
        var arguments = Array(
            ZenCODECommandLineArgumentSanitizer
                .sanitized(rawArguments)
                .dropFirst()
        )
        arguments.removeAll { $0 == option }

        if arguments.contains("--help") || arguments.contains("-h") {
            AgentOutput.standardOutput.writeString(helpText)
            return
        }

        if arguments.contains("--version") {
            AgentOutput.standardOutput.writeString("ZenCODE \(MLXServerCore.version)\n")
            return
        }

        if arguments.contains("--prepare-metal") {
            try MLXMetalLibraryBootstrap.prepareIfNeeded()
            return
        }

        if let option = ZenCODESetupMenuRunner.movedSetupOption(
            in: rawArguments,
            mlxMode: true
        ) {
            throw ZenCODESetupMenuError.setupActionMovedToSetup(option)
        }

        try await runAgent(arguments: arguments)
    }

    @MainActor
    private static func runAgent(arguments: [String]) async throws {
        let options = try ZenCODEMLXOptions(arguments: arguments)
        try AgentRuntimeLauncher.ensureProjectAgentsFileExists(
            workingDirectory: options.workingDirectory
        )
        try MLXMetalLibraryBootstrap.prepareIfNeeded()

        let settings = try MLXServerSettingsStore.loadRequired()
        let modelCatalog = try MLXServerModelsManifestStore.loadRequired().catalog
        let availableAgents = (try? AgentProfileStore.loadRequired())
            ?? AgentProfileStore.defaultProfiles()
        let initialModel = try modelCatalog.resolve(id: options.modelID)
        let runtime = MLXServerRuntime(
            diskKVCacheConfiguration: settings.diskKVCache.configuration,
            modelLoadLogger: nil,
            modelUnloadLogger: nil
        )
        let backendBuilder = MLXLocalAgentRuntimeAdapter(
            modelCatalog: modelCatalog,
            initialModelID: initialModel.id,
            runtime: runtime,
            kvCacheSettings: settings.kvCache
        )
        let backendFactory = backendBuilder.factory
        let permissionAuthorizer = LocalExecPermissionAuthorizer()
        let sessionRunner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            },
            backendFactory: backendFactory
        )
        let configuration = try AgentConfiguration(
            hostedModelID: initialModel.id,
            explicitModelID: options.modelID,
            agentName: options.agentName,
            availableAgents: availableAgents,
            availableModels: modelManifests(
                from: modelCatalog.models,
                kvCacheSettings: settings.kvCache
            ),
            cacheAgentProfiles: options.acp,
            bearerToken: nil,
            runMode: options.acp ? .acp : .chat,
            workingDirectory: options.workingDirectory,
            initialSkillSelection: options.initialSkillSelection,
            maxToolRounds: options.maxToolRounds,
            maxOutputTokens: options.maxOutputTokens,
            verboseLogging: options.verboseLogging,
            appMode: false
        )

        if options.acp {
            if !options.verboseLogging {
                AgentOutput.silenceInheritedProcessError()
            }
            await AgentRuntimeLauncher.runACP(
                configuration: configuration,
                backendFactory: backendFactory
            )
            return
        }

        let stdinIsTerminal = TerminalRawInput.supportsInteractiveInput()
        try await AgentRuntimeLauncher.runTerminalChat(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner
        )
    }

    private static func modelManifests(
        from models: [MLXServerModelDescriptor],
        kvCacheSettings: MLXServerKVCacheSettings
    ) -> [AgentSettingsModelManifest] {
        let kvCacheSettings = kvCacheSettings.validated()
        let providerID = UUID(uuidString: "00000000-0000-0000-0000-000000008080")!
        return models.map { model in
            let provider = AgentRemoteProvider(
                id: providerID,
                name: "ZenCODE MLX",
                baseURL: "local://mlx",
                modelID: model.id
            )
            return AgentSettingsModelManifest(
                id: model.id,
                kind: .remoteAPI,
                title: model.displayName,
                llmID: model.id,
                modelID: model.id,
                provider: provider,
                configuredContextWindowLimit: model.generationDefaults.contextWindow,
                generationParameterOverrides: AgentGenerationParameterOverrides(
                    maxTokens: model.generationDefaults.maxOutputTokens,
                    temperature: model.generationDefaults.temperature.map(Double.init),
                    topP: model.generationDefaults.topP.map(Double.init),
                    topK: model.generationDefaults.topK,
                    repetitionPenalty: model.generationDefaults.repetitionPenalty.map(Double.init),
                    presencePenalty: model.generationDefaults.presencePenalty.map(Double.init),
                    frequencyPenalty: model.generationDefaults.frequencyPenalty.map(Double.init),
                    prefillStepSize: model.generationDefaults.prefillStepSize
                        ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize,
                    kvBits: kvCacheSettings.kvBits,
                    kvGroupSize: kvCacheSettings.kvGroupSize,
                    quantizedKVStart: kvCacheSettings.quantizedKVStart
                ),
                thinkingOptions: thinkingOptions(from: model.thinking),
                defaultThinkingSelection: AgentThinkingSelection(
                    rawValue: model.thinking.defaultSelection.rawValue
                )
            )
        }
    }

    private static func thinkingOptions(
        from thinking: MLXServerModelThinkingConfiguration
    ) -> [AgentThinkingSelection]? {
        guard thinking.supportsThinking else {
            return nil
        }
        let options = thinking.availableSelections.compactMap {
            AgentThinkingSelection(rawValue: $0.rawValue)
        }
        return options.isEmpty ? nil : options
    }

    private static let helpText = """
    zen --mlx

    Local MLX runtime mode for ZenCODE.

    Usage:
      zen --mlx [--help] [--version]
      zen --mlx [--acp] [--cwd <path>] [--model <id>] [--agent <name>] [--skills <list>]
                      [--max-output-tokens <count>] [--max-tool-rounds <count>] [--verbose]

    Run zen --setup for local MLX setup, model setup, and reset options.
    Run zen --mlx to start the ZenCODE TUI with the local MLX runtime directly.
    Add --acp to expose the same direct runtime over ACP stdio.
    """
}

private struct ZenCODEMLXOptions {
    var modelID: String?
    var agentName: String?
    var workingDirectory: URL
    var initialSkillSelection: String?
    var maxToolRounds: Int
    var maxOutputTokens: Int?
    var verboseLogging: Bool
    var acp: Bool

    init(arguments: [String]) throws {
        var modelID: String?
        var agentName: String?
        var workingDirectoryPath = ProcessInfo.processInfo.environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
        var initialSkillSelection: String?
        var maxToolRounds = AgentToolRoundPolicy.defaultMaxToolRounds
        var maxOutputTokens: Int?
        var verboseLogging = false
        var acp = false
        var index = arguments.startIndex

        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--model":
                modelID = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--agent":
                agentName = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--cwd":
                workingDirectoryPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--skills":
                initialSkillSelection = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--max-tool-rounds":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value),
                      AgentToolRoundPolicy.isValidMaxToolRounds(parsed) else {
                    throw ZenCODEMLXError.invalidArgument(argument, value)
                }
                maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(parsed)
            case "--max-output-tokens":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value), parsed > 0 else {
                    throw ZenCODEMLXError.invalidArgument(argument, value)
                }
                maxOutputTokens = parsed
            case "--verbose":
                verboseLogging = true
            case "--acp":
                acp = true
            default:
                throw ZenCODEMLXError.unsupportedArguments([argument])
            }
            index = arguments.index(after: index)
        }

        self.modelID = modelID
        self.agentName = agentName
        self.workingDirectory = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: workingDirectoryPath
        )
        self.initialSkillSelection = initialSkillSelection
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.acp = acp
    }

    private static func requiredValue(
        after flag: String,
        in arguments: [String],
        index: inout Array<String>.Index
    ) throws -> String {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw ZenCODEMLXError.missingRequiredArgument(flag)
        }
        index = valueIndex
        return arguments[valueIndex]
    }
}

private enum ZenCODEMLXError: LocalizedError {
    case unsupportedArguments([String])
    case missingRequiredArgument(String)
    case invalidArgument(String, String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArguments(let arguments):
            return "Unsupported MLX arguments: \(arguments.joined(separator: " ")). Run zen --mlx --help."
        case .missingRequiredArgument(let argument):
            return "Missing required value for \(argument)."
        case .invalidArgument(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        }
    }
}

#else

enum ZenCODEMLXCommand {
    static let option = "--mlx"

    @MainActor
    static func run(arguments rawArguments: [String]) async throws {
        let arguments = Array(
            ZenCODECommandLineArgumentSanitizer
                .sanitized(rawArguments)
                .dropFirst()
        )

        if arguments.contains("--help") || arguments.contains("-h") {
            AgentOutput.standardOutput.writeString(helpText)
            return
        }

        if arguments.contains("--version") {
            AgentOutput.standardOutput.writeString("ZenCODE \(ZenPackageMetadata.version)\n")
            return
        }

        throw ZenCODEMLXUnavailableError.unavailable
    }

    private static let helpText = """
    zen --mlx

    Local MLX runtime mode is not available in this build.

    This binary was built without mlx-swift, so local inference is disabled.
    Configure a remote provider with zen --setup and run ZenCODE without --mlx.
    """
}

private enum ZenCODEMLXUnavailableError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "Local MLX runtime is not available in this build. Configure a remote model with zen --setup and run ZenCODE without --mlx."
        }
    }
}
#endif
