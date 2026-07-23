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

public enum AgentRunMode: String, Sendable {
    case automatic
    case acp
    case chat
}

public enum AgentResolvedRunMode: Sendable {
    case acp
    case chat
}

public struct AgentConfiguration: Sendable {
    public static let helpText = """
    ZenCODE

    Autonomous ZenCODE CLI and ACP agent.

    Usage:
      zen [--acp] [--agent NAME] [--model MODEL_ID] [--cwd PATH] [--skills LIST]

    Modes:
      default                Human terminal chat.
      --acp                  ACP JSON-RPC over stdio for compatible clients.

    Agent runtime:
      --agent NAME           Agent profile from ~/.zencode/agents.json. Default is used when omitted.
      --model MODEL_ID        Model id, remoteapimodel:<uuid>, or remoteapi:<uuid>. Overrides the agent-selected model for this run.
      --cwd PATH              Working directory for local tools. Default: current directory, or home when launched from the executable directory.
      --skills LIST           Initial chat skill selection by name/number, all, or none. In chat mode use /skills to change or install skills.
      --max-tool-rounds N     Maximum model/tool loop rounds per prompt. Default: \(AgentToolRoundPolicy.defaultMaxToolRounds).
      --max-output-tokens N   Maximum generated tokens per model call. Default: model default.
      --verbose               Show status/tool progress on stderr. Default: quiet chat output.

    Tool discovery:
      In chat mode, use /agents to switch agent profiles without restarting the TUI.
      In chat mode, use /tools to enable local, shell, search, git, memory, sub-agent, Xcode, or Figma tools.
      In chat mode, use the Builder agent to create and manage generated Swift feature packages with /feature.
      In chat mode, use /skills to select prompt skills installed by the app or install a skill from GitHub or a local folder.
      In chat mode, use /attach to add image or video files to the next prompt.
      In chat mode, use /changes to review tracked file changes and /undo to revert the latest tracked changes.
      In chat mode, delegated sub-agent status is shown automatically in the chat flow.
      In ACP mode, clients pass the enabled tools to the agent runtime.
      Xcode MCP tools are added when Xcode is running and mcpbridge can expose tools.
      Figma MCP tools are added when the local Figma desktop MCP server exposes tools.

    Environment:
      ZENCODE_AGENT_MODE           chat, acp, or auto. Auto resolves to chat.
      ZENCODE_AGENT_NAME           Agent profile from ~/.zencode/agents.json. Default is used when omitted.
      ZENCODE_AGENT_MODEL          Model id, remoteapimodel:<uuid>, or remoteapi:<uuid>. Overrides the agent-selected model for this run.
      ZENCODE_AGENT_CWD            Working directory for local tools.
      ZENCODE_AGENT_SKILLS         Initial chat skill selection by name/number, all, or none.
      ZENCODE_AGENT_VERBOSE        1/true to show status/tool progress on stderr.
      ZENCODE_AGENT_BEARER_TOKEN   Fallback bearer token for configured remote providers.

    In ACP mode stdout contains only ACP JSON-RPC messages. In chat mode stdout contains only assistant text.
    """

    public let modelID: String?
    public let agentName: String?
    public let selectedAgent: AgentProfile?
    public let effectiveModelID: String?
    public let bearerToken: String?
    public let runMode: AgentRunMode
    public let workingDirectory: URL
    public let initialSkillSelection: String?
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
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
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(rawArguments)
        let environment = ProcessInfo.processInfo.environment
        func agentEnvironmentValue(_ key: String) -> String? {
            environment["ZENCODE_AGENT_\(key)"]
        }

        var rawAgentName = environment["ZENCODE_AGENT"]
            ?? agentEnvironmentValue("NAME")
            ?? agentEnvironmentValue("AGENT")
        var rawModelID = agentEnvironmentValue("MODEL")
        var rawBearerToken = agentEnvironmentValue("BEARER_TOKEN")
        var rawRunMode = agentEnvironmentValue("MODE") ?? "automatic"
        let environmentWorkingDirectory = agentEnvironmentValue("CWD")?.nilIfBlank
        var hasExplicitWorkingDirectory = environmentWorkingDirectory != nil
        var rawWorkingDirectory = environmentWorkingDirectory
            ?? Self.shellWorkingDirectory(environment: environment)
            ?? FileManager.default.currentDirectoryPath
        var rawInitialSkillSelection = agentEnvironmentValue("SKILLS")
        var rawMaxToolRounds = agentEnvironmentValue("MAX_TOOL_ROUNDS")
        var rawMaxOutputTokens = agentEnvironmentValue("MAX_OUTPUT_TOKENS")
        var rawVerboseLogging = agentEnvironmentValue("VERBOSE")
        var shouldPrintHelp = false
        var shouldPrintVersion = false
        var shouldPrintDoctor = false

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
            case "--bearer-token":
                index += 1
                guard index < arguments.count else {
                    throw AgentConfigurationError.missingValue(argument)
                }
                rawBearerToken = arguments[index]
            case "--acp":
                rawRunMode = AgentRunMode.acp.rawValue
            case "--cwd":
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
            case "--verbose":
                rawVerboseLogging = "true"
            default:
                throw AgentConfigurationError.unknownArgument(argument)
            }
            index += 1
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
        let verboseLogging = Self.bool(rawVerboseLogging)
        let appMode = appModeOverride ?? false
        let requestedAgentName = rawAgentName?.nilIfBlank
        let settingsManifest: AgentSettingsManifest?
        let selectedAgent: AgentProfile?
        let agentName: String?
        if shouldPrintHelp || shouldPrintVersion || shouldPrintDoctor {
            settingsManifest = nil
            selectedAgent = nil
            agentName = requestedAgentName
        } else {
            let manifest = try AgentSettingsManifestStore.loadRequired()
            settingsManifest = manifest
            let availableAgents = try AgentProfileStore.loadRequired()
            selectedAgent = try Self.selectedAgent(
                named: requestedAgentName,
                availableAgents: availableAgents
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
        self.selectedAgent = selectedAgent
        self.effectiveModelID = effectiveModelID
        self.bearerToken = rawBearerToken?.nilIfBlank
        self.runMode = runMode
        self.workingDirectory = workingDirectory
        self.initialSkillSelection = rawInitialSkillSelection?.nilIfBlank
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
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
        bearerToken: String? = nil,
        runMode: AgentRunMode = .chat,
        workingDirectory: URL,
        initialSkillSelection: String? = nil,
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        appMode: Bool = false
    ) throws {
        let requestedAgentName = rawAgentName?.nilIfBlank
        let selectedAgent = try Self.selectedAgent(
            named: requestedAgentName,
            availableAgents: availableAgents
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
        self.selectedAgent = selectedAgent
        self.effectiveModelID = effectiveModelID
        self.bearerToken = bearerToken?.nilIfBlank
        self.runMode = runMode
        self.workingDirectory = workingDirectory
        self.initialSkillSelection = initialSkillSelection?.nilIfBlank
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens.map { max(1, $0) }
        self.verboseLogging = verboseLogging
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
        case .automatic:
            return appMode ? .acp : .chat
        }
    }

    public var runtimeConfiguration: AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: effectiveModelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            locksModelToSession: hostedAgentProfiles != nil,
            toolAuthorizationHandler: nil
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
        if let xcodeProjectDirectory = xcodeProjectDirectoryURL() {
            return xcodeProjectDirectory
        }
        return UserHomeDirectory.current()
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func xcodeProjectDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let candidatePaths = [
            environment["SRCROOT"],
            environment["PROJECT_DIR"]
        ].compactMap { value -> String? in
            let path = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.hasPrefix("/") == true ? path : nil
        }

        for path in candidatePaths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            return URL(fileURLWithPath: path)
                .standardizedFileURL
                .resolvingSymlinksInPath()
        }

        return nil
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

    private static func bool(_ rawValue: String?) -> Bool {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "y", "on":
            return true
        default:
            return false
        }
    }

    private static func selectedAgent(
        named rawAgentName: String?,
        availableAgents: [AgentProfile]
    ) throws -> AgentProfile? {
        guard let rawAgentName else {
            return try AgentProfileStore.developerProfile(in: availableAgents)
        }

        let normalizedName = normalizedAgentLookupValue(rawAgentName)
        guard !normalizedName.isEmpty else {
            return nil
        }

        if let agent = availableAgents.first(where: { agent in
            normalizedAgentLookupValue(agent.id) == normalizedName
                || normalizedAgentLookupValue(agent.name) == normalizedName
        }) {
            return agent
        }

        throw AgentConfigurationError.unknownAgent(
            rawAgentName,
            availableAgents.map(\.displayName)
        )
    }

    private static func normalizedAgentLookupValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public enum AgentConfigurationError: LocalizedError {
    case invalidValue(String, String)
    case missingValue(String)
    case unknownAgent(String, [String])
    case unknownArgument(String)

    public var errorDescription: String? {
        switch self {
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
