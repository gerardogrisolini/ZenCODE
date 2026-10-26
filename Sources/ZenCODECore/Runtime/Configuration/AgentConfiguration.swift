//
//  AgentConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
import ToolCore

public enum AgentRunMode: String, Sendable {
    case automatic
    case acp
    case chat
    case headless
}

public enum AgentResolvedRunMode: Sendable {
    case acp
    case chat
    case headless
}

public struct AgentConfiguration: Sendable {
    public static let helpText = """
    ZenCODE

    Autonomous ZenCODE CLI and ACP agent.

    Usage:
      zen [-p PROMPT] [-f PATH] [--jsonl] [--acp] [--agent NAME] [--model MODEL_ID] [--working-directory PATH] [--skills LIST]

    Modes:
      default                Human terminal chat.
      -p, --prompt PROMPT    Run one headless text prompt.
      -f PATH                Run one headless prompt read from a file (absolute path). With -p, the file is added as context.
      --jsonl                Emit headless events and the result as JSON Lines (use with -p/--prompt or -f).
      --acp                  ACP JSON-RPC over stdio for compatible clients.

    Agent runtime:
      --agent NAME           Agent profile from ~/.zencode/agents.json. Default is used when omitted.
      --model MODEL_ID        Model id, remoteapimodel:<uuid>, or remoteapi:<uuid>. Overrides the agent-selected model for this run.
      --working-directory PATH
                              Working directory for local tools. Default: current directory, or home when launched from the executable directory.
      --skills LIST           Initial chat skill selection by name/number, all, or none. In chat mode use /skills to change or install skills.
      --max-tool-rounds N     Maximum model/tool loop rounds per prompt. Default: \(AgentToolRoundPolicy.defaultMaxToolRounds).
      --max-output-tokens N   Maximum generated tokens per model call. Default: model default.

    Tool discovery:
      In chat mode, use /setup to reconfigure ZenCODE and restore the current session without restarting the app.
      In chat mode, use /agents to switch agent profiles without restarting the TUI.
      In chat mode, use /tools to enable local, shell, search, git, memory, sub-agent, or optional feature tools.
      In chat mode, use the Builder agent to create and manage generated Swift feature packages with /feature.
      In chat mode, use /skills to select prompt skills installed by the app or install a skill from GitHub or a local folder.
      In chat mode, use /attach to add image or video files to the next prompt.
      In chat mode, use /changes to review tracked file changes and /undo to revert the latest tracked changes.
      In chat mode, delegated sub-agent status is shown automatically in the chat flow.
      In ACP mode, clients pass the enabled tools to the agent runtime.
      Figma MCP tools are added when the local Figma desktop MCP server exposes tools.

    Environment:
      ZENCODE_AGENT_MODE           chat, acp, headless, or auto. Auto resolves to chat.
      ZENCODE_AGENT_NAME           Agent profile from ~/.zencode/agents.json. Default is used when omitted.
      ZENCODE_AGENT_MODEL          Model id, remoteapimodel:<uuid>, or remoteapi:<uuid>. Overrides the agent-selected model for this run.
      ZENCODE_AGENT_CWD            Working directory for local tools.
      ZENCODE_AGENT_SKILLS         Initial chat skill selection by name/number, all, or none.

    With -p or -f, piped stdin is supplied as additional context.
    In ACP mode stdout contains only ACP JSON-RPC messages. In headless mode stdout contains only the final assistant text, unless `--jsonl` is supplied.
    `--jsonl` is ignored with `--help`, `--version`, `--doctor`, and `--install-features`; those meta-commands keep their normal textual output and exit code.

    Example:
      zen --jsonl -p "Summarize the current changes"
    """

    public let modelID: String?
    public let agentName: String?
    /// The agent profile name explicitly requested (`--agent`, `ZENCODE_AGENT`,
    /// or the hosted `agentName`), trimmed; `nil` when none was requested and
    /// the project's default developer was used instead.
    public let requestedAgentName: String?
    public let selectedAgent: AgentProfile?
    public let effectiveModelID: String?
    public let runMode: AgentRunMode
    /// Enables the machine-readable JSON Lines headless output protocol.
    public let jsonl: Bool
    /// Inline prompt supplied by `-p`; nil is invalid for a headless turn unless
    /// `headlessPromptFile` is set.
    public let headlessPrompt: String?
    /// Absolute path of the prompt file supplied by `-f`, exactly as given. The
    /// file is read when the headless run starts, not when arguments are parsed.
    public let headlessPromptFile: String?
    public let workingDirectory: URL
    public let initialSkillSelection: String?
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let appMode: Bool
    public let printHelp: Bool
    public let printVersion: Bool
    public let printDoctor: Bool
    public let hostedAgentProfiles: [AgentProfile]?
    public let hostedModels: [AgentSettingsModelManifest]?

    public init(
        arguments rawArguments: [String],
        appModeOverride: Bool? = nil
    ) throws {
        try self.init(
            arguments: rawArguments,
            appModeOverride: appModeOverride,
            loadPersistedConfiguration: true
        )
    }

    /// Validates command-line syntax without requiring settings or agent files.
    /// The executable uses this before first-run setup so an unknown option
    /// cannot accidentally launch a mutating setup flow.
    public static func validateArguments(_ rawArguments: [String]) throws {
        _ = try Self(
            arguments: rawArguments,
            appModeOverride: false,
            loadPersistedConfiguration: false
        )
    }

    private init(
        arguments rawArguments: [String],
        appModeOverride: Bool?,
        loadPersistedConfiguration: Bool
    ) throws {
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(rawArguments)
        let environment = ProcessInfo.processInfo.environment
        func agentEnvironmentValue(_ key: String) -> String? {
            environment["ZENCODE_AGENT_\(key)"]
        }

        var rawAgentName = environment["ZENCODE_AGENT"]
            ?? agentEnvironmentValue("NAME")
            ?? agentEnvironmentValue("AGENT")
        var rawModelID = agentEnvironmentValue("MODEL")
        var rawRunMode = agentEnvironmentValue("MODE") ?? "automatic"
        var rawHeadlessPrompt: String?
        var rawHeadlessPromptFile: String?
        var rawJSONL = false
        let environmentWorkingDirectory = agentEnvironmentValue("CWD")?.nilIfBlank
        var hasExplicitWorkingDirectory = environmentWorkingDirectory != nil
        var rawWorkingDirectory = Self.defaultWorkingDirectoryRawPath(environment: environment)
        var rawInitialSkillSelection = agentEnvironmentValue("SKILLS")
        var rawMaxToolRounds = agentEnvironmentValue("MAX_TOOL_ROUNDS")
        var rawMaxOutputTokens = agentEnvironmentValue("MAX_OUTPUT_TOKENS")
        var shouldPrintHelp = false
        var shouldPrintVersion = false
        var shouldPrintDoctor = false
        var explicitlyRequestedACP = false
        var explicitlyRequestedInlinePrompt = false

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--help", "-h":
                shouldPrintHelp = true
            case "--version":
                shouldPrintVersion = true
            case "--doctor":
                shouldPrintDoctor = true
            case "--model":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawModelID = arguments[index]
            case "--agent":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawAgentName = arguments[index]
            case "--acp":
                guard !explicitlyRequestedInlinePrompt else {
                    throw AgentConfigurationError.conflictingOptions("--acp", "-p/--prompt")
                }
                guard rawHeadlessPromptFile == nil else {
                    throw AgentConfigurationError.conflictingOptions("--acp", "-f")
                }
                guard !rawJSONL else {
                    throw AgentConfigurationError.conflictingOptions("--acp", "--jsonl")
                }
                explicitlyRequestedACP = true
                rawRunMode = AgentRunMode.acp.rawValue
            case "--jsonl":
                guard !explicitlyRequestedACP else {
                    throw AgentConfigurationError.conflictingOptions("--jsonl", "--acp")
                }
                rawJSONL = true
                rawRunMode = AgentRunMode.headless.rawValue
            case "-p", "--prompt":
                guard !explicitlyRequestedACP else {
                    throw AgentConfigurationError.conflictingOptions("--acp", "-p/--prompt")
                }
                guard !explicitlyRequestedInlinePrompt else {
                    throw AgentConfigurationError.conflictingOptions(argument, "-p/--prompt")
                }
                explicitlyRequestedInlinePrompt = true
                rawRunMode = AgentRunMode.headless.rawValue
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                let prompt = arguments[index]
                guard prompt != "-" else {
                    throw AgentConfigurationError.invalidValue(argument, prompt)
                }
                guard !prompt.hasPrefix("-") else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawHeadlessPrompt = prompt
            case "-f":
                guard !explicitlyRequestedACP else {
                    throw AgentConfigurationError.conflictingOptions("--acp", argument)
                }
                guard rawHeadlessPromptFile == nil else {
                    throw AgentConfigurationError.conflictingOptions(argument, argument)
                }
                rawRunMode = AgentRunMode.headless.rawValue
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                let path = arguments[index]
                guard path != "-" else {
                    throw AgentConfigurationError.invalidValue(argument, path)
                }
                guard !path.hasPrefix("-") else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                guard ZenCODEPromptFile.isAbsolutePath(path) else {
                    throw AgentConfigurationError.invalidValue(argument, path)
                }
                rawHeadlessPromptFile = path
            case "--working-directory":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawWorkingDirectory = arguments[index]
                hasExplicitWorkingDirectory = true
            case "--skills":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawInitialSkillSelection = arguments[index]
            case "--max-tool-rounds":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawMaxToolRounds = arguments[index]
            case "--max-output-tokens":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawMaxOutputTokens = arguments[index]
            default:
                throw AgentConfigurationError.unknownArgument(argument)
            }
            index += 1
        }

        if rawJSONL,
           rawHeadlessPrompt == nil,
           rawHeadlessPromptFile == nil,
           !shouldPrintHelp,
           !shouldPrintVersion,
           !shouldPrintDoctor {
            throw AgentConfigurationError.missingValue("--prompt")
        }

        let normalizedRunMode = rawRunMode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let runMode = AgentRunMode(rawValue: normalizedRunMode == "auto" ? "automatic" : normalizedRunMode) else {
            throw AgentConfigurationError.invalidValue("--mode", rawRunMode)
        }
        let workingDirectory = Self.resolvedWorkingDirectory(
            rawValue: rawWorkingDirectory,
            applyLaunchDirectoryFallback: !hasExplicitWorkingDirectory
        )
        let maxToolRounds = try Self.maxToolRounds(
            rawMaxToolRounds,
            argument: "--max-tool-rounds"
        )
        let maxOutputTokens = try Self.positiveInt(rawMaxOutputTokens, argument: "--max-output-tokens")
        let appMode = appModeOverride ?? false
        let requestedAgentName = rawAgentName?.nilIfBlank
        let settingsManifest: AgentSettingsManifest?
        let selectedAgent: AgentProfile?
        let agentName: String?
        if shouldPrintHelp || shouldPrintVersion || shouldPrintDoctor || !loadPersistedConfiguration {
            settingsManifest = nil
            selectedAgent = nil
            agentName = requestedAgentName
        } else {
            let snapshot = try PersistedAgentConfigurationSnapshot.loadRequired()
            let manifest = snapshot.settings
            settingsManifest = manifest
            let availableAgents = snapshot.profiles
            selectedAgent = try Self.selectedAgent(
                named: requestedAgentName,
                availableAgents: availableAgents,
                workingDirectory: workingDirectory
            )
            agentName = requestedAgentName ?? selectedAgent?.displayName
        }
        let modelID = rawModelID?.nilIfBlank
        let effectiveModelID = AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: modelID,
            agentModelID: selectedAgent?.modelID,
            manifest: settingsManifest
        )

        self.modelID = modelID
        self.agentName = agentName
        self.requestedAgentName = requestedAgentName
        self.selectedAgent = selectedAgent
        self.effectiveModelID = effectiveModelID
        self.runMode = runMode
        self.jsonl = rawJSONL
        self.headlessPrompt = rawHeadlessPrompt
        self.headlessPromptFile = rawHeadlessPromptFile
        self.workingDirectory = workingDirectory
        self.initialSkillSelection = rawInitialSkillSelection?.nilIfBlank
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.appMode = appMode
        self.printHelp = shouldPrintHelp
        self.printVersion = shouldPrintVersion
        self.printDoctor = shouldPrintDoctor
        self.hostedAgentProfiles = nil
        self.hostedModels = nil
    }

    public init(
        hostedModelID: String,
        explicitModelID rawModelID: String? = nil,
        agentName rawAgentName: String? = nil,
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles(),
        availableModels: [AgentSettingsModelManifest] = [],
        cacheAgentProfiles: Bool = true,
        runMode: AgentRunMode = .chat,
        jsonl: Bool = false,
        workingDirectory: URL,
        initialSkillSelection: String? = nil,
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        appMode: Bool = false
    ) throws {
        let requestedAgentName = rawAgentName?.nilIfBlank
        let selectedAgent = try Self.selectedAgent(
            named: requestedAgentName,
            availableAgents: availableAgents,
            workingDirectory: workingDirectory
        )
        let normalizedModelID = hostedModelID.nilIfBlank
        let requestedModelID = rawModelID?.nilIfBlank
        let hostedManifest = AgentSettingsManifest(
            models: availableModels,
            selectedModelID: normalizedModelID
        )
        let effectiveModelID = AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: requestedModelID,
            agentModelID: nil,
            manifest: hostedManifest
        ) ?? normalizedModelID

        self.modelID = requestedModelID
        self.agentName = requestedAgentName ?? selectedAgent?.displayName
        self.requestedAgentName = requestedAgentName
        self.selectedAgent = selectedAgent
        self.effectiveModelID = effectiveModelID
        self.runMode = runMode
        self.jsonl = jsonl
        self.headlessPrompt = nil
        self.headlessPromptFile = nil
        self.workingDirectory = workingDirectory
        self.initialSkillSelection = initialSkillSelection?.nilIfBlank
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens.map { max(1, $0) }
        self.appMode = appMode
        self.printHelp = false
        self.printVersion = false
        self.printDoctor = false
        self.hostedAgentProfiles = cacheAgentProfiles ? availableAgents : nil
        self.hostedModels = availableModels
    }

    public func resolvedRunMode(stdinIsTerminal _: Bool) -> AgentResolvedRunMode {
        switch runMode {
        case .acp:
            return .acp
        case .chat:
            return .chat
        case .headless:
            return .headless
        case .automatic:
            return appMode ? .acp : .chat
        }
    }

    /// Projects only the shared runtime fields. The context window limit and
    /// the generation parameter overrides are intentionally omitted: the CLI
    /// configuration does not own them, so the runtime defaults apply.
    @available(*, deprecated, message: "Use AgentCoreSessionConfiguration.runtimeConfiguration")
    public var runtimeConfiguration: AgentRuntimeConfiguration {
        projectedRuntimeConfiguration(
            locksModelToSession: hostedAgentProfiles != nil,
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            profileID: selectedAgent?.id,
            profileName: selectedAgent?.name,
            profileRole: selectedAgent?.role
        )
    }

    public static func resolvedWorkingDirectory(
        rawValue: String,
        applyLaunchDirectoryFallback: Bool = true
    ) -> URL {
        let candidate = URL(fileURLWithPath: rawValue)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard applyLaunchDirectoryFallback,
              let executableDirectory = executableDirectoryURL(),
              sameFilePath(candidate, executableDirectory) else {
            return candidate
        }
        return UserHomeDirectory.current()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// The working directory used when no `--working-directory` argument is
    /// given: `ZENCODE_AGENT_CWD`, else the shell's absolute and existing `PWD`,
    /// else the process's current directory.
    static func defaultWorkingDirectoryRawPath(environment: [String: String]) -> String {
        environment["ZENCODE_AGENT_CWD"]?.nilIfBlank
            ?? shellWorkingDirectory(environment: environment)
            ?? FileManager.default.currentDirectoryPath
    }

    /// The directory a launch with `arguments` and `environment` works in,
    /// resolved like the full parser does but without validating any other
    /// option: the last `--working-directory <value>` wins over the default.
    /// For flows that run before (or without) building a configuration, such as
    /// `/setup`, which still has to know which project the session belongs to.
    static func launchWorkingDirectoryURL(
        arguments: [String],
        environment: [String: String]
    ) -> URL {
        var argumentValue: String?
        var index = 1
        while index < arguments.count {
            if arguments[index] == "--working-directory", index + 1 < arguments.count {
                argumentValue = arguments[index + 1]
                index += 2
            } else {
                index += 1
            }
        }
        let hasExplicitWorkingDirectory = argumentValue != nil
            || environment["ZENCODE_AGENT_CWD"]?.nilIfBlank != nil
        return resolvedWorkingDirectory(
            rawValue: argumentValue ?? defaultWorkingDirectoryRawPath(environment: environment),
            applyLaunchDirectoryFallback: !hasExplicitWorkingDirectory
        )
    }

    private static func shellWorkingDirectory(environment: [String: String]) -> String? {
        guard let path = environment["PWD"]?.nilIfBlank,
              path.hasPrefix("/") else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return path
    }

    private static func executableDirectoryURL() -> URL? {
        guard let executableURL = Bundle.main.executableURL else {
            return nil
        }
        return executableURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    private static func sameFilePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func maxToolRounds(_ rawValue: String?, argument: String) throws -> Int {
        guard let rawValue = rawValue?.nilIfBlank else {
            return AgentToolRoundPolicy.defaultMaxToolRounds
        }
        guard let value = Int(rawValue),
              AgentToolRoundPolicy.isValidMaxToolRounds(value) else {
            throw AgentConfigurationError.invalidValue(argument, rawValue)
        }
        return AgentToolRoundPolicy.normalizedMaxToolRounds(value)
    }

    private static func positiveInt(_ rawValue: String?, argument: String) throws -> Int? {
        guard let rawValue = rawValue?.nilIfBlank else {
            return nil
        }
        guard let value = Int(rawValue), value > 0 else {
            throw AgentConfigurationError.invalidValue(argument, rawValue)
        }
        return value
    }

    private static func selectedAgent(
        named rawAgentName: String?,
        availableAgents: [AgentProfile],
        workingDirectory: URL
    ) throws -> AgentProfile? {
        guard let rawAgentName else {
            return try AgentProfileStore.developerProfile(
                in: availableAgents,
                workspaceRootURL: workingDirectory
            )
        }

        let normalizedName = TextUtilities.normalizedLookupValue(rawAgentName)
        guard !normalizedName.isEmpty else {
            return nil
        }

        if let agent = availableAgents.first(where: { agent in
            TextUtilities.normalizedLookupValue(agent.id) == normalizedName
                || TextUtilities.normalizedLookupValue(agent.name) == normalizedName
        }) {
            return agent
        }

        throw AgentConfigurationError.unknownAgent(
            rawAgentName,
            availableAgents.map(\.displayName)
        )
    }

}

public enum AgentConfigurationError: LocalizedError {
    case conflictingOptions(String, String)
    case invalidValue(String, String)
    case missingValue(String)
    case unknownAgent(String, [String])
    case unknownArgument(String)

    public var errorDescription: String? {
        switch self {
        case let .conflictingOptions(first, second):
            return "Options \(first) and \(second) cannot be combined."
        case let .invalidValue(argument, value):
            return "Invalid value for \(argument): \(value)"
        case let .missingValue(argument):
            return "Missing value for \(argument)."
        case let .unknownAgent(name, availableAgents):
            let available = availableAgents.isEmpty
                ? "No agents are configured in \(AgentProfileStore.agentsManifestURL().path)."
                : "Available agents: \(availableAgents.joined(separator: ", "))."
            return "Unknown agent '\(name)'. \(available)"
        case let .unknownArgument(argument):
            return "Unknown argument: \(argument)"
        }
    }
}
