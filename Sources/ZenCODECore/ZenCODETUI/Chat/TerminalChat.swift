//
//  TerminalChat.swift
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

/// Detail level used when rendering executed tool calls in the terminal.
public enum ToolOutputDetailLevel: CaseIterable, Sendable {
    /// Single inline status line per tool call.
    case compact
    /// Title, kind, location, and change/summary/error snippets.
    case medium
    /// Same as `medium` plus the full call parameters, with wider limits.
    case detail

    /// Returns the next level when cycling through detail levels.
    public var next: ToolOutputDetailLevel {
        switch self {
        case .compact: return .medium
        case .medium: return .detail
        case .detail: return .compact
        }
    }

    /// Human-readable label used in status messages.
    public var label: String {
        switch self {
        case .compact: return "compact"
        case .medium: return "medium"
        case .detail: return "detail"
        }
    }
}

/// TerminalChat is driven by a single terminal event loop; @Sendable callbacks capture it to hop back into that loop.
public final class TerminalChat: @unchecked Sendable {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    public let sessionRunner: AgentCoreSessionRunner
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public var sessionID = TerminalChat.newTerminalSessionID()
    public var activeSessionCacheKey: String?
    public var activeSessionHistory: [AgentRuntimeMessage] = []
    public var activeSessionTranscript: [AgentRuntimeMessage] = []
    public var activeSessionSystemPromptOverride: String?
    public var activeResponseLanguageName: String?
    public var didLockResponseLanguage = false
    public var activeSavedSessionName: String?
    public var printedModelID: String?
    public var didPrintActiveTools = false
    public var didReceiveMetricsForCurrentPrompt = false
    public var didRefreshGitStatusDuringCurrentPrompt = false
    public var selectedAgent: AgentProfile?
    public var manualModelIDOverride: String?
    public var manualThinkingSelectionOverride: AgentThinkingSelection?
    public var selectedToolKeys = Set<String>()
    public var selectedSkillIDs = Set<String>()
    public var pendingAttachments: [AgentRuntimeAttachment] = []
    public var lastFileChangeSummary: TurnFileChangeSummary?
    public var lastRenderedSubAgentOverviewSignature: String?
    public var availableSkillsCache: [MLXPromptSkill]?
    public var toolOutputDetailLevel: ToolOutputDetailLevel = .compact
    public var activeCompactToolCallID: String?
    public var activeCompactToolRenderedRowCount = 0
    public var activeDetailedToolCallID: String?
    public var activeDetailedToolRenderedRowCount = 0
    public var isStreamingThoughtOutput = false

    var assistantBoldBreakState = TerminalChatBoldBreakState()
    var thoughtBoldBreakState = TerminalChatBoldBreakState()
    var isAtStartOfChatLine = true
    var trailingChatNewlineCount = 0
    public var assistantMarkdownFormatter = TerminalMarkdownStreamFormatter(
        isEnabled: AgentOutput.standardOutputIsTerminal
    )
    public var thoughtMarkdownFormatter = TerminalMarkdownStreamFormatter(
        isEnabled: AgentOutput.standardErrorIsTerminal,
        removesUnbalancedStrongMarkers: true
    )
    public let telegramControlService = TerminalTelegramControlService()
    let telegramPermissionBroker = TerminalTelegramPermissionBroker()
    public var telegramControlState = TerminalTelegramControlState.inactive()
    public var telegramLinkedChatID: Int64?
    public var telegramLinkedChatTitle: String?
    public let voiceRecordingService = TerminalVoiceRecordingService()
    public var activeVoiceRecordingSession: TerminalVoiceRecordingSession?
    public var lastAssistantResponseText: String?
    var optionalCommandAvailability = TerminalOptionalCommandAvailability.load()

    public let statusBar: TerminalStatusBar

    public init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil
    ) {
        self.configuration = configuration
        self.stdinIsTerminal = stdinIsTerminal
        self.statusBar = TerminalStatusBar(
            isEnabled: stdinIsTerminal
                && Self.supportsInteractiveStatusBar()
        )
        let permissionAuthorizer = LocalExecPermissionAuthorizer()
        self.permissionAuthorizer = permissionAuthorizer
        self.sessionRunner = sessionRunner ?? AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            }
        )
        self.selectedAgent = configuration.selectedAgent
        self.manualModelIDOverride = configuration.modelID
    }

    public static func supportsInteractiveStatusBar() -> Bool {
        AgentOutput.standardErrorIsTerminal
    }

    public static func newTerminalSessionID() -> String {
        "terminal-\(UUID().uuidString.lowercased())"
    }

    public func currentEffectiveModelID() -> String? {
        if let hostedModelManifest = hostedModelSelectionManifest() {
            return AgentSettingsStore.resolvedEffectiveModelID(
                explicitModelID: manualModelIDOverride,
                agentModelID: selectedAgent?.modelID,
                manifest: hostedModelManifest
            ) ?? configuration.effectiveModelID
        }

        return Self.effectiveModelID(
            selectedAgent: selectedAgent,
            manualModelIDOverride: manualModelIDOverride
        ) ?? configuration.effectiveModelID
    }

    public static func effectiveModelID(
        selectedAgent: AgentProfile?,
        manualModelIDOverride: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: manualModelIDOverride,
            agentModelID: selectedAgent?.modelID,
            manifest: manifest
        )
    }

    private func hostedModelSelectionManifest() -> AgentSettingsManifest? {
        guard let hostedModels = configuration.hostedModels else {
            return nil
        }
        return AgentSettingsManifest(
            models: hostedModels,
            selectedModelID: configuration.effectiveModelID
        )
    }

    public func run() async throws {
        let sleepAssertion = ZenCODESleepAssertion(
            reason: "ZenCODE terminal session active"
        )
        defer {
            sleepAssertion.invalidate()
        }

        let initialInputLine: String?
        if stdinIsTerminal {
            initialInputLine = nil
        } else {
            guard let line = reader.readLine() else {
                throw TerminalChatError.noInputReceived
            }
            initialInputLine = line
        }

        await applyInitialAgentSelectionIfNeeded()
        try handleMissingInitialModelSelectionIfNeeded()
        try applyInitialSkillSelectionIfNeeded()
        await ensureWorkspaceAccessIfNeeded()

        try await createCurrentSession()
        refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)

        if stdinIsTerminal {
            AgentOutput.clearTerminalScreenIfNeeded()
        }
        await printStartupSummary()

        let statusBarStarted = statusBar.start()
        refreshStatusBarGitStatusSummary()
        defer {
            Task {
                _ = await telegramControlService.stop()
            }
            statusBar.stop()
        }

        if stdinIsTerminal, statusBarStarted {
            try await runInteractivePanelLoop()
        } else {
            try await runBlockingInputLoop(initialInputLine: initialInputLine)
        }

        await sessionRunner.closeSession(id: sessionID)
    }

}
