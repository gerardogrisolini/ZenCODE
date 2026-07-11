//
//  ZenCODEDS4Command.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
import ZenPackageMetadata

enum ZenCODEDS4Command {
    static let option = "--ds4"

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
            AgentOutput.standardOutput.writeString("ZenCODE \(ZenPackageMetadata.version)\n")
            return
        }

        if arguments.contains("--doctor") {
            arguments.removeAll { $0 == "--doctor" }
            try runDoctor(arguments: arguments)
            return
        }

        try await runAgent(arguments: arguments)
    }

    private static func runDoctor(arguments: [String]) throws {
        let options = try ZenCODEDS4Options(arguments: arguments)
        let runtimeOptions = options.runtimeOptions
        AgentOutput.standardOutput.writeString(
            """
            DS4 configuration OK

              settings: \(DS4SettingsStore.settingsURL().path)
              root:     \(runtimeOptions.ds4Root.path)
              library:  \(runtimeOptions.libraryURL.path)
              model:    \(runtimeOptions.modelURL.path)
              backend:  \(runtimeOptions.backend.rawValue)
              ctx:      \(runtimeOptions.contextWindow)
              output:   \(options.maxOutputTokens.map(String.init) ?? "default")
              tools:    \(options.maxToolRounds)
              threads:  \(runtimeOptions.nThreads == 0 ? "default" : String(runtimeOptions.nThreads))
              prefill:  \(runtimeOptions.prefillChunk == 0 ? "default" : String(runtimeOptions.prefillChunk))
              ssd:      \(Self.ssdStreamingDescription(runtimeOptions))
              mtp:      \(Self.mtpDescription(runtimeOptions))
              sampling: temp \(Self.formatFloat(runtimeOptions.temperature)), top-k \(runtimeOptions.topK == 0 ? "off" : String(runtimeOptions.topK)), top-p \(Self.formatFloat(runtimeOptions.topP)), min-p \(Self.formatFloat(runtimeOptions.minP)), seed \(runtimeOptions.seed == 0 ? "default" : String(runtimeOptions.seed))

            """
        )
    }

    private static func ssdStreamingDescription(_ options: DS4RuntimeOptions) -> String {
        guard options.ssdStreaming else {
            return "off"
        }
        var parts = ["on"]
        if options.ssdStreamingCacheBytes > 0 {
            parts.append("cache \(formatBytes(options.ssdStreamingCacheBytes))")
        } else if options.ssdStreamingCacheExperts > 0 {
            parts.append("cache \(options.ssdStreamingCacheExperts) experts")
        }
        if options.ssdStreamingPreloadExperts > 0 {
            parts.append("preload \(options.ssdStreamingPreloadExperts) experts")
        }
        if options.ssdStreamingCold {
            parts.append("cold")
        }
        return parts.joined(separator: ", ")
    }

    private static func mtpDescription(_ options: DS4RuntimeOptions) -> String {
        guard let mtpURL = options.mtpURL else {
            return "off"
        }
        return "\(mtpURL.path), draft \(options.mtpDraftTokens), margin \(formatFloat(options.mtpMargin))"
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824.0
        if gib.rounded() == gib {
            return "\(Int(gib))GB"
        }
        return String(format: "%.1fGB", gib)
    }

    private static func formatFloat(_ value: Float) -> String {
        String(format: "%.4g", Double(value))
    }

    @MainActor
    private static func runAgent(arguments: [String]) async throws {
        let options = try ZenCODEDS4Options(arguments: arguments)
        try AgentRuntimeLauncher.ensureProjectAgentsFileExists(
            workingDirectory: options.workingDirectory
        )

        let availableAgents = (try? AgentProfileStore.loadRequired())
            ?? AgentProfileStore.defaultProfiles()
        let runtimeOptions = options.runtimeOptions
        let backendBuilder = DS4LocalAgentRuntimeAdapter(runtimeOptions: runtimeOptions)
        let backendFactory = backendBuilder.factory
        let permissionAuthorizer = LocalExecPermissionAuthorizer()
        let sessionRunner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            },
            backendFactory: backendFactory
        )
        let configuration = try AgentConfiguration(
            hostedModelID: runtimeOptions.modelID,
            explicitModelID: options.modelID,
            agentName: options.agentName,
            availableAgents: availableAgents,
            availableModels: [modelManifest(from: runtimeOptions)],
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

    private static func modelManifest(
        from options: DS4RuntimeOptions
    ) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000D504")!,
            name: "ZenCODE DS4",
            baseURL: "local://ds4",
            modelID: options.modelID
        )
        return AgentSettingsModelManifest(
            id: options.modelID,
            kind: .remoteAPI,
            title: options.modelURL.lastPathComponent,
            llmID: options.modelID,
            modelID: options.modelID,
            provider: provider,
            configuredContextWindowLimit: options.contextWindow,
            generationParameterOverrides: AgentGenerationParameterOverrides(
                maxTokens: options.maxOutputTokens,
                temperature: Double(options.temperature),
                topP: Double(options.topP),
                minP: Double(options.minP)
            ),
            thinkingOptions: [.off, .enabled, .high, .xhigh],
            defaultThinkingSelection: .high
        )
    }

    private static let helpText = """
    zen --ds4

    Local DS4 runtime mode for ZenCODE. This uses DS4 in-process through a local libds4 dynamic library, not ds4-server.

    Usage:
      zen --ds4 [--help] [--version]
      zen --ds4 [--doctor] [--ds4-root <path>] [--model <gguf>] [--acp] [--cwd <path>] [--agent <name>] [--skills <list>]
                       [--ctx <tokens>] [--max-output-tokens <count>] [--max-tool-rounds <count>] [--verbose]
                       [--ssd-streaming] [--ssd-streaming-cache-experts <N|NGB>]

    Configuration:
      ~/.zencode/ds4/settings.json is used when --ds4-root is omitted.
      CLI arguments override environment variables, which override that file.

    Environment:
      ZENCODE_DS4_ROOT       DS4 source/build directory.
      ZENCODE_DS4_LIBRARY    libds4.dylib path. Default: <root>/libds4.dylib.
      ZENCODE_DS4_MODEL      GGUF path. Overrides the model selected in setup.
      ZENCODE_DS4_TOP_K      Top-k sampling cutoff. 0 disables top-k.

    Build the local library with:
      Scripts/build-ds4-runtime.sh /path/to/ds4

    Install DS4 runtime once with:
      Scripts/setup-ds4.sh /path/to/ds4

    Select the DS4 model from:
      zen --setup

    DS4 mode uses native DSML tool calls in-process and does not start ds4-server.
    """
}

private struct ZenCODEDS4Options {
    var modelID: String?
    var agentName: String?
    var workingDirectory: URL
    var initialSkillSelection: String?
    var maxToolRounds: Int
    var maxOutputTokens: Int?
    var verboseLogging: Bool
    var acp: Bool
    var runtimeOptions: DS4RuntimeOptions

    init(arguments: [String]) throws {
        let environment = ProcessInfo.processInfo.environment
        let configuredSettings = try DS4SettingsStore.load()
        var ds4RootPath = environment["ZENCODE_DS4_ROOT"]?.nilIfBlank
            ?? configuredSettings?.ds4Root.nilIfBlank
        var libraryPath = environment["ZENCODE_DS4_LIBRARY"]?.nilIfBlank
            ?? configuredSettings?.libraryPath?.nilIfBlank
        var modelPath = environment["ZENCODE_DS4_MODEL"]?.nilIfBlank
            ?? configuredSettings?.modelPath?.nilIfBlank
        var modelID: String?
        var agentName: String?
        var workingDirectoryPath = environment["PWD"]
            ?? FileManager.default.currentDirectoryPath
        var initialSkillSelection: String?
        var maxToolRounds = configuredSettings?.maxToolRounds
            ?? AgentToolRoundPolicy.defaultMaxToolRounds
        var maxOutputTokens: Int? = environment["ZENCODE_DS4_MAX_OUTPUT_TOKENS"].flatMap(Int.init)
            ?? configuredSettings?.maxOutputTokens
        var verboseLogging = false
        var acp = false
        var backend = try configuredSettings?.backend
            .map(Self.backend) ?? Self.defaultBackend()
        var contextWindow = environment["ZENCODE_DS4_CTX"].flatMap(Int.init)
            ?? configuredSettings?.contextWindow
            ?? 65536
        var nThreads = configuredSettings?.nThreads ?? 0
        var prefillChunk: UInt32 = configuredSettings?.prefillChunk ?? 0
        var mtpDraftTokens = configuredSettings?.mtpDraftTokens ?? 1
        var mtpMargin: Float = configuredSettings?.mtpMargin ?? 3.0
        var powerPercent = configuredSettings?.powerPercent ?? 100
        var ssdStreaming = configuredSettings?.ssdStreaming ?? false
        var ssdStreamingCold = configuredSettings?.ssdStreamingCold ?? false
        var ssdStreamingCacheExperts: UInt32 = configuredSettings?.ssdStreamingCacheExperts ?? 0
        var ssdStreamingCacheBytes: UInt64 = configuredSettings?.ssdStreamingCacheBytes ?? 0
        var ssdStreamingPreloadExperts: UInt32 = configuredSettings?.ssdStreamingPreloadExperts ?? 0
        var quality = configuredSettings?.quality ?? false
        var temperature: Float = configuredSettings?.temperature ?? 1.0
        var topK: Int = environment["ZENCODE_DS4_TOP_K"].flatMap(Int.init)
            ?? configuredSettings?.topK ?? 0
        var topP: Float = configuredSettings?.topP ?? 1.0
        var minP: Float = configuredSettings?.minP ?? 0.05
        var seed: UInt64 = configuredSettings?.seed ?? 0
        var mtpPath = configuredSettings?.mtpPath

        if let envBackend = environment["ZENCODE_DS4_BACKEND"]?.nilIfBlank {
            backend = try Self.backend(envBackend)
        }
        if let envStreaming = environment["ZENCODE_DS4_SSD_STREAMING"] {
            ssdStreaming = Self.bool(envStreaming)
        }
        if let envCache = environment["ZENCODE_DS4_SSD_STREAMING_CACHE_EXPERTS"]?.nilIfBlank {
            let parsed = try Self.streamingCache(envCache)
            ssdStreamingCacheExperts = parsed.experts
            ssdStreamingCacheBytes = parsed.bytes
        }

        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            switch argument {
            case "--ds4-root":
                ds4RootPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--library", "--lib":
                libraryPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--model":
                modelPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
                modelID = modelPath
            case "--agent":
                agentName = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--cwd":
                workingDirectoryPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--skills":
                initialSkillSelection = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--ctx", "-c":
                contextWindow = try Self.positiveInt(argument, arguments: arguments, index: &index)
            case "--threads", "-t":
                nThreads = try Self.positiveInt(argument, arguments: arguments, index: &index)
            case "--prefill-chunk":
                prefillChunk = try Self.nonNegativeUInt32(argument, arguments: arguments, index: &index)
            case "--max-output-tokens", "--tokens", "-n":
                maxOutputTokens = try Self.positiveInt(argument, arguments: arguments, index: &index)
            case "--max-tool-rounds":
                let value = try Self.requiredValue(after: argument, in: arguments, index: &index)
                guard let parsed = Int(value),
                      AgentToolRoundPolicy.isValidMaxToolRounds(parsed) else {
                    throw ZenCODEDS4Error.invalidArgument(argument, value)
                }
                maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(parsed)
            case "--temp":
                temperature = try Self.float(argument, arguments: arguments, index: &index)
            case "--top-k":
                topK = try Self.nonNegativeInt(argument, arguments: arguments, index: &index)
            case "--top-p":
                topP = try Self.float(argument, arguments: arguments, index: &index)
            case "--min-p":
                minP = try Self.float(argument, arguments: arguments, index: &index)
            case "--seed":
                seed = UInt64(try Self.positiveInt(argument, arguments: arguments, index: &index))
            case "--power":
                powerPercent = try Self.positiveInt(argument, arguments: arguments, index: &index)
            case "--backend":
                backend = try Self.backend(try Self.requiredValue(after: argument, in: arguments, index: &index))
            case "--metal":
                backend = .metal
            case "--cuda":
                backend = .cuda
            case "--cpu":
                backend = .cpu
            case "--ssd-streaming":
                ssdStreaming = true
            case "--ssd-streaming-cold":
                ssdStreamingCold = true
            case "--ssd-streaming-cache-experts":
                let parsed = try Self.streamingCache(
                    try Self.requiredValue(after: argument, in: arguments, index: &index)
                )
                ssdStreamingCacheExperts = parsed.experts
                ssdStreamingCacheBytes = parsed.bytes
            case "--ssd-streaming-preload-experts":
                ssdStreamingPreloadExperts = try Self.nonNegativeUInt32(argument, arguments: arguments, index: &index)
            case "--mtp":
                mtpPath = try Self.requiredValue(after: argument, in: arguments, index: &index)
            case "--mtp-draft-tokens":
                mtpDraftTokens = try Self.positiveInt(argument, arguments: arguments, index: &index)
            case "--mtp-margin":
                mtpMargin = try Self.float(argument, arguments: arguments, index: &index)
            case "--quality":
                quality = true
            case "--verbose":
                verboseLogging = true
            case "--acp":
                acp = true
            default:
                throw ZenCODEDS4Error.unsupportedArguments([argument])
            }
            index = arguments.index(after: index)
        }

        let ds4Root = try Self.resolvedDS4Root(ds4RootPath)
        let libraryURL = URL(fileURLWithPath: libraryPath?.nilIfBlank ?? ds4Root.appendingPathComponent(Self.defaultLibraryName()).path)
            .standardizedFileURL
        let modelURL = try Self.resolvedModelURL(modelPath)
        try Self.validateFile(libraryURL, description: "DS4 runtime library")

        self.modelID = modelID ?? modelURL.path
        self.agentName = agentName
        self.workingDirectory = AgentConfiguration.resolvedWorkingDirectory(
            rawValue: workingDirectoryPath
        )
        self.initialSkillSelection = initialSkillSelection
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens.map { max(1, $0) }
        self.verboseLogging = verboseLogging
        self.acp = acp
        self.runtimeOptions = DS4RuntimeOptions(
            ds4Root: ds4Root,
            libraryURL: libraryURL,
            modelURL: modelURL,
            mtpURL: mtpPath.map { URL(fileURLWithPath: $0).standardizedFileURL },
            backend: backend,
            contextWindow: min(max(contextWindow, 1), 1_048_576),
            nThreads: nThreads,
            prefillChunk: prefillChunk,
            mtpDraftTokens: mtpDraftTokens,
            mtpMargin: mtpMargin,
            powerPercent: min(max(powerPercent, 1), 100),
            ssdStreamingCacheExperts: ssdStreamingCacheExperts,
            ssdStreamingCacheBytes: ssdStreamingCacheBytes,
            ssdStreamingPreloadExperts: ssdStreamingPreloadExperts,
            ssdStreaming: ssdStreaming,
            ssdStreamingCold: ssdStreamingCold,
            quality: quality,
            maxOutputTokens: maxOutputTokens,
            temperature: min(max(temperature, 0), 2),
            topK: max(topK, 0),
            topP: min(max(topP, 0.01), 1),
            minP: min(max(minP, 0), 1),
            seed: seed
        )
    }

    private static func resolvedDS4Root(_ rawValue: String?) throws -> URL {
        if let rawValue = rawValue?.nilIfBlank {
            let url = URL(fileURLWithPath: rawValue).standardizedFileURL
            try validateDirectory(url, description: "DS4 root")
            return url
        }
        throw ZenCODEDS4Error.missingDS4Root
    }

    private static func resolvedModelURL(_ rawValue: String?) throws -> URL {
        if let rawValue = rawValue?.nilIfBlank {
            let url = URL(fileURLWithPath: rawValue).standardizedFileURL
            try validateFile(url, description: "DS4 model")
            return url
        }
        throw ZenCODEDS4Error.missingModelSelection
    }

    private static func defaultBackend() -> DS4RuntimeOptions.Backend {
        #if os(macOS)
        return .metal
        #else
        return .cpu
        #endif
    }

    private static func defaultLibraryName() -> String {
        #if os(macOS)
        return "libds4.dylib"
        #else
        return "libds4.so"
        #endif
    }

    private static func backend(_ rawValue: String) throws -> DS4RuntimeOptions.Backend {
        guard let backend = DS4RuntimeOptions.Backend(
            rawValue: rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        ) else {
            throw ZenCODEDS4Error.invalidArgument("--backend", rawValue)
        }
        return backend
    }

    private static func streamingCache(_ rawValue: String) throws -> (experts: UInt32, bytes: UInt64) {
        let uppercased = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if uppercased == "0" {
            return (0, 0)
        }
        if uppercased.hasSuffix("GB") || uppercased.hasSuffix("GIB") {
            let suffix = uppercased.hasSuffix("GIB") ? "GIB" : "GB"
            let number = String(uppercased.dropLast(suffix.count))
            guard let value = Double(number), value > 0 else {
                throw ZenCODEDS4Error.invalidArgument("--ssd-streaming-cache-experts", rawValue)
            }
            return (0, UInt64(value * 1_073_741_824.0))
        }
        guard let experts = UInt32(uppercased), experts > 0 else {
            throw ZenCODEDS4Error.invalidArgument("--ssd-streaming-cache-experts", rawValue)
        }
        return (experts, 0)
    }

    private static func bool(_ rawValue: String) -> Bool {
        ["1", "true", "yes", "on"].contains(
            rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        )
    }

    private static func positiveInt(
        _ flag: String,
        arguments: [String],
        index: inout Array<String>.Index
    ) throws -> Int {
        let value = try requiredValue(after: flag, in: arguments, index: &index)
        guard let parsed = Int(value), parsed > 0 else {
            throw ZenCODEDS4Error.invalidArgument(flag, value)
        }
        return parsed
    }

    private static func nonNegativeInt(
        _ flag: String,
        arguments: [String],
        index: inout Array<String>.Index
    ) throws -> Int {
        let value = try requiredValue(after: flag, in: arguments, index: &index)
        guard let parsed = Int(value), parsed >= 0 else {
            throw ZenCODEDS4Error.invalidArgument(flag, value)
        }
        return parsed
    }

    private static func nonNegativeUInt32(
        _ flag: String,
        arguments: [String],
        index: inout Array<String>.Index
    ) throws -> UInt32 {
        let value = try requiredValue(after: flag, in: arguments, index: &index)
        guard let parsed = UInt32(value) else {
            throw ZenCODEDS4Error.invalidArgument(flag, value)
        }
        return parsed
    }

    private static func float(
        _ flag: String,
        arguments: [String],
        index: inout Array<String>.Index
    ) throws -> Float {
        let value = try requiredValue(after: flag, in: arguments, index: &index)
        guard let parsed = Float(value) else {
            throw ZenCODEDS4Error.invalidArgument(flag, value)
        }
        return parsed
    }

    private static func requiredValue(
        after flag: String,
        in arguments: [String],
        index: inout Array<String>.Index
    ) throws -> String {
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw ZenCODEDS4Error.missingRequiredArgument(flag)
        }
        index = valueIndex
        return arguments[valueIndex]
    }

    private static func validateDirectory(_ url: URL, description: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ZenCODEDS4Error.missingPath(description, url)
        }
    }

    private static func validateFile(_ url: URL, description: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw ZenCODEDS4Error.missingPath(description, url)
        }
    }
}

private enum ZenCODEDS4Error: LocalizedError {
    case unsupportedArguments([String])
    case missingRequiredArgument(String)
    case invalidArgument(String, String)
    case missingDS4Root
    case missingModelSelection
    case missingPath(String, URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedArguments(let arguments):
            return "Unsupported DS4 arguments: \(arguments.joined(separator: " ")). Run zen --ds4 --help."
        case .missingRequiredArgument(let argument):
            return "Missing required value for \(argument)."
        case .invalidArgument(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .missingDS4Root:
            return "Missing DS4 root. Run Scripts/setup-ds4.sh /path/to/ds4, pass --ds4-root /path/to/ds4, or set ZENCODE_DS4_ROOT."
        case .missingModelSelection:
            return "No DS4 model selected. Run zen --setup, choose Local inference, then DS4 models."
        case .missingPath(let description, let url):
            return "\(description) not found at \(url.path). If libds4.dylib is missing, run Scripts/build-ds4-runtime.sh /path/to/ds4."
        }
    }
}
