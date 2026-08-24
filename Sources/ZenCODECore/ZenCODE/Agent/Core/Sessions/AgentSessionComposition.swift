//
//  AgentSessionComposition.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// Non-mutating helpers shared by every entry point that builds an
/// ``AgentCoreSessionConfiguration``: the app session factory and the
/// interactive terminal chat.
///
/// Nothing here reads or mutates the session task graph. `SessionTaskOrchestrator`
/// remains its only mutable owner, and `AgentCoreSessionRunner` remains the
/// coordination center; these helpers only compose immutable values.
public enum AgentSessionComposition {
    // MARK: - Tool allowlist

    /// Single definition of the "memory tools are available" rule.
    ///
    /// A `nil` allowlist means the caller did not restrict the tool surface, so
    /// memory tools are considered available.
    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    /// Whether an explicit memory-tool allowlist grants reads but no mutation.
    /// An unrestricted (`nil`) surface includes mutation-capable memory tools.
    static func memoryToolsAreReadOnly(_ allowedToolNames: Set<String>?) -> Bool {
        guard allowedToolNames != nil else { return false }
        let grants: (ToolDescriptor) -> Bool = { descriptor in
            DirectToolExecutor.isAllowed(
                descriptor.name,
                allowedToolNames: allowedToolNames
            )
        }
        return MemoryTool.readOnlyToolDescriptors.contains(where: grants)
            && !MemoryTool.mutatingToolDescriptors.contains(where: grants)
    }

    /// Adds the intrinsic prompt-skill tools to an explicit allowlist.
    ///
    /// Both skill tools are always-on, so they must survive any user tool
    /// selection. Keeping the union in one place also keeps the tool schema —
    /// and therefore the remote cache identity — stable across selection
    /// changes. A `nil` allowlist already allows every tool and is returned
    /// unchanged.
    public static func allowedToolNamesIncludingIntrinsicSkillTools(
        _ allowedToolNames: Set<String>?
    ) -> Set<String>? {
        guard var allowedToolNames else {
            return nil
        }
        allowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
        return allowedToolNames
    }

    /// Non-optional convenience for callers that always own a concrete
    /// allowlist, such as the terminal chat.
    public static func allowedToolNamesIncludingIntrinsicSkillTools(
        _ allowedToolNames: Set<String>
    ) -> Set<String> {
        var allowedToolNames = allowedToolNames
        allowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
        return allowedToolNames
    }

    // MARK: - System prompt

    /// Composes the standard standalone prompt sections shared by the app
    /// factory and the terminal chat.
    ///
    /// - Parameters:
    ///   - locksModelToSession: Hosted runs pin the model to the session and
    ///     therefore omit the delegatable-agents section.
    ///   - responseLanguageSection: Supplied by the caller that owns the
    ///     session language; `nil` keeps the prompt builder default.
    public static func standardSystemPrompt(
        cwd: String,
        allowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?,
        locksModelToSession: Bool = false,
        responseLanguageSection: String? = nil
    ) -> String {
        standardPromptSections(
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent,
            locksModelToSession: locksModelToSession,
            responseLanguageSection: responseLanguageSection
        )
        .combinedPrompt
    }

    /// Produces the stable standalone instruction prefix independently from
    /// context that can change while the session is alive.
    public static func standardPromptSections(
        cwd: String,
        allowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?,
        locksModelToSession: Bool = false,
        responseLanguageSection: String? = nil
    ) -> SystemPromptSections {
        let memoryToolEnabled = memoryToolEnabled(allowedToolNames)
        return AgentStandaloneSystemPrompt.promptSections(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            locksModelToSession: locksModelToSession,
            selectedAgentSection: selectedAgent?.promptSection(
                memoryToolEnabled: memoryToolEnabled
            ),
            selectedSkillSection: SystemPromptBuilder.staticSkillSection,
            responseLanguageSection: responseLanguageSection
        )
    }

    /// Wraps an app-provided prompt with the standard context sections.
    ///
    /// The caller-provided text stays authoritative: agent/workflow sections
    /// are appended as mutable user context, while working-directory, skill,
    /// and language instructions remain in the stable system prefix.
    public static func appProvidedSystemPrompt(
        _ providedSystemPrompt: String,
        cwd: String? = nil,
        allowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?,
        responseLanguageSection: String? = SystemPromptBuilder.responseLanguageSection()
    ) -> String {
        appProvidedPromptSections(
            providedSystemPrompt,
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent,
            responseLanguageSection: responseLanguageSection
        )
        .combinedPrompt
    }

    /// Keeps application-provided system instructions authoritative while
    /// moving tool-, agent-, and workflow-specific state into the session's
    /// initial user context. Working-directory and language state remain part
    /// of the stable provider system prefix.
    public static func appProvidedPromptSections(
        _ providedSystemPrompt: String,
        cwd: String? = nil,
        allowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?,
        responseLanguageSection: String? = SystemPromptBuilder.responseLanguageSection()
    ) -> SystemPromptSections {
        let memoryToolEnabled = memoryToolEnabled(allowedToolNames)
        let alreadyHasSkillSection = providedSystemPrompt.contains(
            SystemPromptBuilder.staticSkillSectionMarker
        )
        let systemSections = [
            providedSystemPrompt,
            alreadyHasSkillSection ? nil : SystemPromptBuilder.staticSkillSection,
            cwd.map(SystemPromptBuilder.workingDirectorySection(path:)),
            responseLanguageSection
        ]
        .compactMap { $0?.nilIfBlank }
        let dynamicContext = cwd.map {
            AgentStandaloneSystemPrompt.promptSections(
                cwd: $0,
                memoryToolEnabled: memoryToolEnabled,
                allowedToolNames: allowedToolNames,
                selectedAgentSection: selectedAgent?.promptSection(
                    memoryToolEnabled: memoryToolEnabled
                ),
                selectedSkillSection: SystemPromptBuilder.staticSkillSection
            )
            .dynamicContext
        } ?? [
            selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled),
            SystemPromptBuilder.taskOrchestrationSection(
                allowedToolNames: allowedToolNames
            ),
            memoryToolEnabled
                ? MemoryService.toolUsagePromptSection(
                    readOnly: memoryToolsAreReadOnly(allowedToolNames)
                )
                : nil
        ]
        .compactMap { $0?.nilIfBlank }
        .joined(separator: "\n\n")
        return SystemPromptSections(
            systemPrompt: systemSections.joined(separator: "\n\n"),
            dynamicContext: dynamicContext
        )
    }
}

/// Shared builder for the fields every ``AgentCoreSessionConfiguration`` call
/// site provides.
///
/// Interactive state (active plan progress, history overrides, prompt
/// overrides) stays with the terminal chat: the builder receives the already
/// resolved values. The builder never creates or mutates the task graph.
public struct AgentCoreSessionConfigurationBuilder: Sendable {
    public var sessionID: String
    public var modelID: String?
    public var agentID: String?
    public var agentName: String?
    public var workingDirectory: URL
    public var systemPrompt: String?
    public var dynamicContext: String?
    public var cacheKey: String?
    public var sessionRevision: Int
    public var history: [AgentRuntimeMessage]
    public var allowedToolNames: Set<String>?
    public var maxToolRounds: Int
    public var maxOutputTokens: Int?
    public var verboseLogging: Bool
    public var appMode: Bool
    public var thinkingSelection: AgentThinkingSelection?
    public var preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String?,
        agentID: String? = nil,
        agentName: String? = nil,
        workingDirectory: URL,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        cacheKey: String?,
        sessionRevision: Int = 0,
        history: [AgentRuntimeMessage] = [],
        allowedToolNames: Set<String>? = nil,
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        appMode: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.agentID = agentID
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt
        self.dynamicContext = dynamicContext
        self.cacheKey = cacheKey
        self.sessionRevision = sessionRevision
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.maxToolRounds = maxToolRounds
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.appMode = appMode
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }

    /// Builds the session identity. Trimming, clamping, and allowlist
    /// normalization stay in ``AgentCoreSessionConfiguration``'s initializer.
    public func makeConfiguration() -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            agentID: agentID,
            agentName: agentName,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision,
            history: history,
            allowedToolNames: AgentSessionComposition
                .allowedToolNamesIncludingIntrinsicSkillTools(allowedToolNames),
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}
