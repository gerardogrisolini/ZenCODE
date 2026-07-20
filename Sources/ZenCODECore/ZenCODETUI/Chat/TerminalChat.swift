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
    /// Title, kind, location, full call parameters, and change/summary/error
    /// snippets with syntax-highlighted code areas.
    case expanded

    /// Returns the other level when toggling between detail levels.
    public var next: ToolOutputDetailLevel {
        switch self {
        case .compact: return .expanded
        case .expanded: return .compact
        }
    }

    /// Human-readable label used in status messages.
    public var label: String {
        switch self {
        case .compact: return "compact"
        case .expanded: return "expanded"
        }
    }
}

/// TerminalChat coordinates session state; all stateful terminal rendering is isolated by `renderCoordinator`.
public final class TerminalChat: @unchecked Sendable {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    public let sessionRunner: AgentCoreSessionRunner
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public let featureRuntime = SwiftFeatureRuntime()
    public var sessionID = TerminalChat.newTerminalSessionID()
    public var activeSessionCacheKey: String?
    public var activeSessionHistory: [AgentRuntimeMessage] = []
    public var activeSessionTranscript: [AgentRuntimeMessage] = []
    public var activeSessionSystemPromptOverride: String?
    public var activeResponseLanguageName: String?
    public var didLockResponseLanguage = false
    public var activeSavedSessionName: String?
    /// Tracks the checkpoint tree for the active session. Populated when a
    /// session is loaded or saved, and updated as messages accumulate.
    public var activeCheckpointTree: SessionCheckpointTree?
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
    public var activePlan: TerminalSessionPlan?
    public var taskGraphObserverTask: Task<Void, Never>?
    /// Periodically republishes the sub-agent overview while a blocking
    /// `agent.*` tool call (e.g. `agent.wait`) is executing. Started from
    /// `.toolCallStarted` and stopped from `.toolCallCompleted` / end-of-turn.
    var subAgentOverviewRefreshTask: Task<Void, Never>?
    /// Interval between automatic sub-agent overview refreshes. Exposed as a
    /// mutable instance property so tests can shorten it.
    var subAgentOverviewRefreshInterval = Duration.seconds(2)
    /// Keys of sub-agent completions already reflected in the statusbar git
    /// summary (agent ID + status + output revision). A sub-agent re-run via
    /// `agent.message` produces a new revision and triggers a fresh refresh.
    var reflectedSubAgentCompletionKeys = Set<String>()
    /// Test hook invoked at the start of each refresh tick. When set, the tick
    /// awaits this closure before rendering, allowing tests to deterministically
    /// gate tick timing. Captured at `start` time; `nil` in production.
    var onSubAgentOverviewTick: (@Sendable () async -> Void)?
    public var availableSkillsCache: [PromptSkill]?
    let renderCoordinator: TerminalChatRenderCoordinator
    public let telegramControlService = TerminalTelegramControlService()
    let telegramPermissionBroker = TerminalTelegramPermissionBroker()
    public var telegramControlState = TerminalTelegramControlState.inactive()
    public var telegramLinkedChatID: Int64?
    public var telegramLinkedChatTitle: String?
    public let voiceRecordingService = TerminalVoiceRecordingService()
    public var activeVoiceRecordingSession: TerminalVoiceRecordingSession?
    var optionalCommandAvailability = TerminalOptionalCommandAvailability.load()

    public let statusBar: TerminalStatusBar

    public init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil
    ) {
        self.configuration = configuration
        self.stdinIsTerminal = stdinIsTerminal
        self.renderCoordinator = TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal
        )
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

    deinit {
        taskGraphObserverTask?.cancel()
        subAgentOverviewRefreshTask?.cancel()
    }

    public static func supportsInteractiveStatusBar() -> Bool {
        AgentOutput.standardErrorIsTerminal
    }

    public static func newTerminalSessionID() -> String {
        "terminal-\(UUID().uuidString.lowercased())"
    }

    public func currentEffectiveModelID() -> String? {
        let manifest = hostedModelSelectionManifest()
            ?? AgentSettingsManifestStore.load()
        let resolved = Self.effectiveModelID(
            selectedAgent: selectedAgent,
            manualModelIDOverride: manualModelIDOverride,
            manifest: manifest
        )
        return resolved ?? configuration.effectiveModelID
    }

    public static func effectiveModelID(
        selectedAgent: AgentProfile?,
        manualModelIDOverride: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        if let manualModelIDOverride = manualModelIDOverride?.nilIfBlank {
            return resolvedConfiguredModelID(
                matching: manualModelIDOverride,
                manifest: manifest,
                preservesUnknownReference: true
            )
        }

        if let defaultModelID = selectedAgent?.defaultModelBinding?.modelID {
            return resolvedConfiguredModelID(
                matching: defaultModelID,
                manifest: manifest,
                preservesUnknownReference: false
            )
        }

        return AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: nil,
            agentModelID: nil,
            manifest: manifest
        )
    }

    /// Resolves a configured manifest identifier for a profile default or a
    /// manual selection. A manual reference is retained when it is external to
    /// the manifest, matching the command-line explicit-model behavior. A
    /// profile default instead falls through to the global selection when its
    /// binding no longer names a configured model.
    private static func resolvedConfiguredModelID(
        matching modelID: String,
        manifest: AgentSettingsManifest?,
        preservesUnknownReference: Bool
    ) -> String? {
        guard let manifest else {
            return modelID
        }
        let references = Self.modelReferences(for: modelID)
        if let model = manifest.models.first(where: { model in
            references.contains { model.matches($0) }
        }) {
            return model.id
        }
        return preservesUnknownReference ? modelID : nil
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

    /// Returns the direct identifier plus the model component of an internal
    /// remote API identifier. The latter intentionally does not require a UUID
    /// provider segment because hosted transports can use opaque provider IDs.
    static func modelReferences(for rawModelID: String) -> [String] {
        let modelID = rawModelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            return []
        }
        var references = [modelID]
        let prefixes = ["remoteapi:", "remoteapimodel:"]
        if let prefix = prefixes.first(where: {
            modelID.lowercased().hasPrefix($0)
        }) {
            let remainder = modelID.dropFirst(prefix.count)
            if let separator = remainder.firstIndex(of: ":") {
                let modelComponent = String(remainder[remainder.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !modelComponent.isEmpty {
                    references.append(modelComponent)
                }
            }
        }
        var seen = Set<String>()
        return references.filter { reference in
            seen.insert(reference.lowercased()).inserted
        }
    }

    public func run() async throws {
        let sleepAssertion = ZenSleepAssertion(
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
        try await handleMissingInitialModelSelectionIfNeeded()
        try applyInitialSkillSelectionIfNeeded()
        await ensureWorkspaceAccessIfNeeded()

        try await createCurrentSession()
        await refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)

        if stdinIsTerminal {
            AgentOutput.clearTerminalScreenIfNeeded()
        }
        await printStartupSummary()

        let statusBarStarted = await statusBar.start()
        await refreshStatusBarGitStatusSummary()
        do {
            if stdinIsTerminal, statusBarStarted {
                try await runInteractivePanelLoop()
            } else {
                try await runBlockingInputLoop(initialInputLine: initialInputLine)
            }

            await sessionRunner.closeSession(id: sessionID)
        } catch {
            await stopTerminalServices()
            throw error
        }
        await stopTerminalServices()
    }

    private func stopTerminalServices() async {
        _ = await telegramControlService.stop()
        await statusBar.stop()
    }
}
