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
import ToolCore

/// TerminalChat coordinates session state; all stateful terminal rendering is isolated by `renderCoordinator`.
///
/// Isolation: every instance member lives on ``TerminalChatActor``, which
/// replaces the previous `@unchecked Sendable` contract with compiler-checked
/// isolation. Blocking POSIX reads must never run on this actor; they are
/// dispatched off-actor through the `…OffActor` helpers in
/// `TerminalChat+InputLoop.swift`.
@TerminalChatActor
public final class TerminalChat {
    public let configuration: AgentConfiguration
    public let stdinIsTerminal: Bool
    public let sessionRunner: AgentCoreSessionRunner
    let runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot?
    public let reader = StdioLineReader()
    public let interactiveReader = TerminalInteractiveLineReader()
    public let permissionAuthorizer: LocalExecPermissionAuthorizer
    public let featureRuntime = SwiftFeatureRuntime()
    public var sessionID = TerminalChat.newTerminalSessionID()
    public var activeSessionCacheKey: String?
    public var activeSessionHistory: [AgentRuntimeMessage] = []
    public var activeSessionTranscript: [AgentRuntimeMessage] = []
    public var activeSessionSystemPromptOverride: String?
    public var activeSessionDynamicContextOverride: String?
    public var activeResponseLanguageName: String?
    public var didLockResponseLanguage = false
    public var activeSavedSessionName: String?
    /// Tracks the checkpoint tree for the active session. Populated when a
    /// session is loaded or saved, and updated as messages accumulate.
    public var activeCheckpointTree: SessionCheckpointTree?
    public var printedModelID: String?
    public var didPrintActiveTools = false
    /// Tracks whether the status-bar git summary has already been refreshed
    /// during the current prompt. Read and written by both the periodic
    /// sub-agent overview refresh task and the generation callback; their
    /// accesses are serialized by ``TerminalChatActor`` isolation.
    var didRefreshGitStatusDuringCurrentPrompt = false
    public var selectedAgent: AgentProfile?
    public var manualModelIDOverride: String?
    public var manualThinkingSelectionOverride: AgentThinkingSelection?
    public var selectedToolKeys = Set<String>()
    public var selectedSkillIDs = Set<String>()
    public var pendingAttachments: [AgentRuntimeAttachment] = []
    public var lastFileChangeSummary: TurnFileChangeSummary?
    public var activePlan: TerminalSessionPlan?
    /// Ephemeral `/plan` clarification state. Never copy this into snapshots or
    /// persisted session models.
    var planBrainstorming: TerminalPlanBrainstormingState?
    public var taskGraphObserverTask: Task<Void, Never>?
    /// In-flight debounced task-graph render scheduled by the observer task.
    /// Tracked on the chat so a turn boundary can quiesce the debounce before
    /// retiring its Telegram reporter.
    var taskGraphDebouncedRender: Task<Void, Never>?
    /// Periodically republishes the sub-agent overview while a blocking
    /// `agent.*` tool call (e.g. `agent.wait`) is executing. Started from
    /// `.toolCallStarted` and stopped from `.toolCallCompleted` / end-of-turn.
    var subAgentOverviewRefreshTask: Task<Void, Never>?
    /// The runner retains this handler across backend rebuilds, so each terminal
    /// installs it once and delegated tools can outlive their spawning turn.
    var didInstallSubAgentToolEventHandler = false
    /// Interval between automatic sub-agent overview refreshes. Exposed as a
    /// mutable instance property so tests can shorten it.
    var subAgentOverviewRefreshInterval = Duration.seconds(2)
    /// Keys of sub-agent completions already reflected in the statusbar git
    /// summary (agent ID + status + output revision). A sub-agent re-run via
    /// `agent.message` produces a new revision and triggers a fresh refresh.
    /// Mutated by the periodic overview refresh task and the generation
    /// callback, which are serialized by ``TerminalChatActor`` isolation.
    var reflectedSubAgentCompletionKeys = Set<String>()

    /// Records a sub-agent completion key and returns whether it was new (so
    /// the caller refreshes the git summary at most once per completion).
    /// The check-then-act pair is atomic because the whole type is isolated to
    /// ``TerminalChatActor``.
    func recordSubAgentCompletionKey(_ key: String) -> Bool {
        reflectedSubAgentCompletionKeys.insert(key).inserted
    }

    /// Test hook invoked at the start of each refresh tick. When set, the tick
    /// awaits this closure before rendering, allowing tests to deterministically
    /// gate tick timing. Captured at `start` time; `nil` in production.
    var onSubAgentOverviewTick: (@Sendable () async -> Void)?
    public var availableSkillsCache: [PromptSkill]?
    let renderCoordinator: TerminalChatRenderCoordinator
    public let telegramControlService: TerminalTelegramControlService
    let telegramPermissionBroker = TerminalTelegramPermissionBroker()
    public var telegramControlState = TerminalTelegramControlState.inactive()
    public var telegramLinkedChatID: Int64?
    public var telegramLinkedChatTitle: String?
    /// Origin of the turn currently generating. Unlike the reporter itself,
    /// this remains populated while Telegram is off so `/telegram on` can attach
    /// the in-flight turn without waiting for the next prompt.
    var activeTelegramTurnOrigin: TerminalPromptOrigin?
    /// Ordered Telegram channel of the turn currently generating, when that
    /// turn's progress is mirrored to the linked chat. Permission dialogue is
    /// enqueued here so it cannot overtake the tool activity that raised it.
    var activeTelegramProgressReporter: TerminalTelegramTurnProgressReporter?
    /// Test seam for direct turn-message delivery when no progress reporter owns
    /// the linked chat. `nil` in production.
    var onDirectTelegramTurnMessage: (@Sendable (TerminalTelegramTurnPayload, Int64) async -> Bool)?
    /// Presentation emitted while a Telegram coordinator command is handled
    /// synchronously. `nil` outside that narrow transport adapter scope.
    var telegramImmediateCommandOutput: [String]?
    /// Test seam for bot-control messages. Production sends through the service.
    var onTelegramSystemMessage: (@Sendable (String, Int64) async -> Bool)?
    /// `true` when the root response block currently streaming already produced
    /// visible text. Used to detect that a Telegram on/off transition happened
    /// in the middle of a response.
    var telegramRootResponseBlockHasContent = false
    /// `true` when the root response block currently streaming must not be
    /// mirrored: part of it was produced while Telegram was off, so publishing
    /// the remainder would send a partial suffix of a response the remote chat
    /// never saw the beginning of. Cleared at the next boundary, where a new
    /// block starts.
    var telegramRootResponseBlockIsSuppressed = false
    /// `true` when at least one intermediate root response was already mirrored
    /// during the current turn, so the accumulated turn text must not be
    /// mirrored again as the final response.
    var telegramDidPublishIntermediateRootResponse = false
    /// Change signature of the task-graph overview already mirrored to Telegram
    /// during the current turn, so republished identical content does not spam
    /// the remote chat. Sub-agent overviews are terminal-only. Reset when a new
    /// turn begins.
    var mirroredTaskGraphOverviewSignature: String?
    /// Mirroring epoch of the current turn. Advanced (via the coordinator) at
    /// every turn boundary and compared against the epoch each notification
    /// carried at enqueue time: a notification delivered after its turn ended
    /// is discarded instead of being adopted by the next turn's reporter.
    var currentTelegramMirrorEpoch = 0
    var optionalCommandAvailability = TerminalOptionalCommandAvailability.load()
    var requestedRuntimeSetup = false
    /// True only while the interactive panel loop, the single surface that
    /// consumes Telegram ingress, is running. The blocking fallback still
    /// forwards live messages, but nothing there reads what Telegram sends back,
    /// so cards must not invite a reply that would be silently dropped.
    var readsTelegramIngress = false
    /// Backing storage for ``telegramSharedChatRelay``. The relay captures this
    /// chat weakly to reach the Telegram transport, so it cannot be built in
    /// `init` as a stored `let` without capturing a partially initialised self.
    /// It stays module-internal so tests can install a relay with a stubbed
    /// sender instead of reaching the network.
    var telegramSharedChatRelayStorage: TerminalTelegramSharedChatRelay?

    /// Forwards operator-directed shared-chat messages to the linked chat and
    /// resolves Telegram replies back to their sender. Created on first use and
    /// owned for the whole chat lifetime, so its ledger survives
    /// `/telegram off` → `/telegram on`.
    var telegramSharedChatRelay: TerminalTelegramSharedChatRelay {
        if let relay = telegramSharedChatRelayStorage {
            return relay
        }
        let relay = TerminalTelegramSharedChatRelay { [weak self] text, chatID in
            await self?.sendTelegramSharedChatCard(text, to: chatID) ?? nil
        }
        telegramSharedChatRelayStorage = relay
        return relay
    }

    public let statusBar: TerminalStatusBar

    public convenience init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil
    ) {
        self.init(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner,
            permissionAuthorizer: permissionAuthorizer,
            runtimeSetupResumeSnapshot: runtimeSetupResumeSnapshot,
            telegramTransportFactory: nil
        )
    }

    /// Internal seam: lets a test drive the production Telegram transport
    /// stack (polling, filtering, sending) through a fake HTTP transport while
    /// every other subsystem stays the real one.
    init(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil,
        telegramTransportFactory: (@Sendable () -> any TelegramHTTPTransport)?
    ) {
        self.configuration = configuration
        self.stdinIsTerminal = stdinIsTerminal
        self.runtimeSetupResumeSnapshot = runtimeSetupResumeSnapshot
        self.renderCoordinator = TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal
        )
        self.statusBar = TerminalStatusBar(
            isEnabled: stdinIsTerminal
                && Self.supportsInteractiveStatusBar()
        )
        let permissionAuthorizer = permissionAuthorizer ?? LocalExecPermissionAuthorizer()
        self.permissionAuthorizer = permissionAuthorizer
        self.sessionRunner = sessionRunner ?? AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in
                await permissionAuthorizer.authorize(request)
            }
        )
        self.selectedAgent = configuration.selectedAgent
        self.manualModelIDOverride = configuration.modelID
        self.telegramControlService = TerminalTelegramControlService(
            transportFactory: telegramTransportFactory ?? { NIOTelegramHTTPTransport() }
        )
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
        for reference in references {
            if let model = manifest.models.first(where: { $0.matches(reference) }) {
                return model.id
            }
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

    public func run() async throws -> TerminalChatRunOutcome {
        let sleepAssertion = ZenSleepAssertion(
            reason: "ZenCODE terminal session active"
        )
        defer {
            sleepAssertion.invalidate()
        }
        await installOverviewMirroringHandler()

        let initialInputLine: String?
        if stdinIsTerminal {
            initialInputLine = nil
        } else {
            guard let line = await Self.readStdinLineOffActor(reader: reader) else {
                throw TerminalChatError.noInputReceived
            }
            initialInputLine = line
        }

        applyRuntimeSetupResumeSnapshotIfNeeded()
        await applyInitialAgentSelectionIfNeeded()
        try await handleMissingInitialModelSelectionIfNeeded()
        try applyInitialSkillSelectionIfNeeded()
        await ensureWorkspaceAccessIfNeeded()

        let resumedTaskGraph = runtimeSetupResumeSnapshot == nil
            ? await applyResumableTaskGraphSessionIfNeeded()
            : nil

        try await createCurrentSession()
        await refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)

        if stdinIsTerminal {
            AgentOutput.clearTerminalScreenIfNeeded()
        }
        await printStartupSummary()
        if let resumedTaskGraph {
            await writeResumedTaskGraphNotice(resumedTaskGraph)
        }
        if let runtimeSetupResumeSnapshot {
            await renderSavedSessionHistory(runtimeSetupResumeSnapshot.transcriptHistory)
            await writeSystemMessage("Session restored after setup.\n")
        }

        let statusBarStarted = await statusBar.start()
        await refreshStatusBarGitStatusSummary()
        do {
            if stdinIsTerminal, statusBarStarted {
                try await runInteractivePanelLoop()
            } else {
                try await runBlockingInputLoop(initialInputLine: initialInputLine)
            }

            let outcome: TerminalChatRunOutcome
            if requestedRuntimeSetup {
                outcome = .setupRequested(await makeRuntimeSetupResumeSnapshot())
            } else {
                outcome = .exited
            }
            await abandonPlanBrainstorming()
            await sessionRunner.closeSession(id: sessionID)
            await stopTerminalServices()
            return outcome
        } catch {
            await stopTerminalServices()
            throw error
        }
    }

    private func stopTerminalServices() async {
        // Quiesce the relay before the transport it uses: its drain worker must
        // not outlive the service it sends through.
        await telegramSharedChatRelayStorage?.shutdown()
        _ = await telegramControlService.stop()
        await statusBar.stop()
    }
}
