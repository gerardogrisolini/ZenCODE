//
//  ChatSessionHostDedicatedRunnerTests.swift
//  ZenCODE
//
//  The slots of a host that run on a dedicated runner: a sibling of the
//  host's runner per slot, sharing the MCP runtime, the feature runtime, the
//  backend factory, the task-graph store, and the registries, with its own
//  backend, sessions, task orchestrator, and access mode; a model change in
//  one slot that leaves the backend and the sessions of another slot alone;
//  the runner session disposed of on the incarnation's runner only; the
//  close of a slot and the host's shutdown that shut the dedicated runners
//  down and keep the external tools until the host's runner goes; the
//  Telegram channel on the slot's runner; and the delegated tool events
//  routed per runner, with the snapshots of that runner. Every test runs in
//  directories named by UUIDs; nothing touches the real application state
//  and no provider is contacted.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

/// A runtime backend created for one runner by the test's factory: it
/// records its model, its sessions, the sessions closed, the prompts, and
/// its shutdowns, and keeps the sub-agent tool event handler the runner
/// handed it, with sub-agent snapshots set by the test.
private actor DedicatedRunnerTestBackend: AgentRuntimeBackend {
    nonisolated let modelID: String?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var closedSessionIDs: [String] = []
    private(set) var prompts: [String] = []
    private(set) var shutdownCount = 0
    private var handler: DirectSubAgentToolEventHandler?
    private var snapshots: [DirectSubAgentRuntime.AgentSnapshot] = []

    init(modelID: String?) {
        self.modelID = modelID
    }

    func sessionIDs() -> Set<String> {
        Set(sessions.keys)
    }

    func hasSubAgentToolEventHandler() -> Bool {
        handler != nil
    }

    func setSubAgentSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        self.snapshots = snapshots
    }

    /// Emits `event` through the handler, as a delegated agent does.
    func emit(_ event: DirectSubAgentToolEvent) async {
        await handler?(event)
    }

    func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) {
        self.handler = handler
    }

    func subAgentSnapshots() -> [DirectSubAgentRuntime.AgentSnapshot] {
        snapshots
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: modelID ?? "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history,
            cacheKey: cacheKey, allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        closedSessionIDs.append(id)
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        shutdownCount += 1
        sessions.removeAll()
    }

    func preloadModel(onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String {
        modelID ?? "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        await onEvent(.content("done"))
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: modelID ?? "test-model")
    }
}

/// Records, as `<agent>:<call>`, the delegated tool events a slot presents.
private actor ToolEventRecordingPresenter: ChatSessionPresenter {
    private(set) var events: [String] = []

    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        events.append("\(event.agentID):\(event.toolCall.id)")
    }
}

/// Every backend the test's factory created, in order.
private final class DedicatedRunnerBackendLog: Sendable {
    let backends = Mutex<[DedicatedRunnerTestBackend]>([])

    var count: Int {
        backends.withLock { $0.count }
    }
}

@ChatSessionActor
@Suite("Chat session host dedicated runners", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionHostDedicatedRunnerTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let mcpRuntime = DirectMCPToolRuntime()
        let backendLog = DedicatedRunnerBackendLog()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-chat-host-dedicated-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// A host over a runner on `mcpRuntime` whose factory creates a new
        /// backend for every backend a runner builds, with a task-graph store
        /// in the support directory; two hosted models.
        @ChatSessionActor
        func makeHost() throws -> ChatSessionHost {
            let log = backendLog
            let runner = AgentCoreSessionRunner(
                mcpRuntime: mcpRuntime,
                backendFactory: { configuration, _ in
                    let backend = DedicatedRunnerTestBackend(modelID: configuration.modelID)
                    log.backends.withLock { $0.append(backend) }
                    return backend
                },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
            let configuration = try AgentConfiguration(
                hostedModelID: "model-a",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "model-a", kind: .remoteAPI, modelID: "local/model-a"),
                    AgentSettingsModelManifest(id: "model-b", kind: .remoteAPI, modelID: "local/model-b"),
                ],
                workingDirectory: workspace
            )
            return ChatSessionHost(
                runner: runner,
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE chat host dedicated runner test"
            )
        }

        /// A slot that publishes state, on a dedicated runner when asked.
        @ChatSessionActor
        func descriptor(
            _ name: String,
            dedicated: Bool,
            presenter: any ChatSessionPresenter = RecordingChatPresenter()
        ) -> ChatSlotDescriptor {
            ChatSlotDescriptor(
                identity: .window(name),
                workingDirectory: workspace,
                presenter: presenter,
                interaction: .pendingRequests(capabilities: [.textInput]),
                authorizer: ChatToolConsentAuthorizer(
                    host: ScriptedChatInteractionHost(capabilities: [], decisions: [])
                ),
                defaultOrigin: .app,
                publishesState: true,
                usesDedicatedRunner: dedicated
            )
        }
    }

    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.chat-host-dedicated-runners") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    private static func runTurn(_ prompt: String, on incarnation: ChatSessionIncarnation) async throws {
        let controller = incarnation.controller
        _ = try await controller.runTurn(
            ChatTurnRequest(
                prompt: prompt,
                sessionConfiguration: await controller.currentSessionConfiguration(responseLanguageSection: nil)
            )
        )
    }

    /// The test backend `runner` runs on now; `nil` before it built one.
    private static func backend(of runner: AgentCoreSessionRunner) async -> DedicatedRunnerTestBackend? {
        guard let coreBackend = await runner.backend else { return nil }
        return await coreBackend.activeBackend as? DedicatedRunnerTestBackend
    }

    private static func readCall(_ id: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: "local.read", argumentsObject: ["path": "a.swift"], argumentsJSON: "{}")
    }

    private static func agentSnapshot(id: String, rootSessionID: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id, rootSessionID: rootSessionID, name: id, status: .running,
            pending: true, latestOutput: nil, executionRevision: 1,
            completedExecutionRevision: 0, latestOutputRevision: 0, latestError: nil,
            createdAt: .now, updatedAt: .now
        )
    }

    // MARK: - Runners

    @Test
    nonisolated func dedicatedSlotsRunOnDistinctSiblingsOfTheHostRunner() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let first = try host.openSlot(environment.descriptor("first", dedicated: true))
            let second = try host.openSlot(environment.descriptor("second", dedicated: true))
            let shared = try host.openSlot(environment.descriptor("shared", dedicated: false))
            let alsoShared = try host.openSlot(environment.descriptor("also-shared", dedicated: false))

            let firstRunner = try #require(host.runner(in: first))
            let secondRunner = try #require(host.runner(in: second))
            #expect(firstRunner !== secondRunner)
            #expect(firstRunner !== host.runner)
            #expect(secondRunner !== host.runner)
            #expect(host.runner(in: shared) === host.runner)
            #expect(host.runner(in: alsoShared) === host.runner)
            #expect(host.dedicatedRunners.count == 2)

            // What is process-wide is shared; the orchestrator is the
            // sibling's own, over the same store.
            #expect(await firstRunner.mcpRuntime === environment.mcpRuntime)
            #expect(await secondRunner.mcpRuntime === environment.mcpRuntime)
            #expect(firstRunner.swiftFeatureRuntime === host.runner.swiftFeatureRuntime)
            #expect(await firstRunner.backendFactory != nil)
            #expect(await firstRunner.ds4EngineRegistry === host.runner.ds4EngineRegistry)
            #expect(await firstRunner.memoryGraphStoreRegistry === host.runner.memoryGraphStoreRegistry)
            let hostOrchestrator = await host.runner.taskOrchestrator
            let firstOrchestrator = await firstRunner.taskOrchestrator
            let secondOrchestrator = await secondRunner.taskOrchestrator
            #expect(firstOrchestrator !== hostOrchestrator)
            #expect(firstOrchestrator !== secondOrchestrator)
            let supportPath = environment.support.standardizedFileURL.path
            #expect(await firstOrchestrator.store?.supportDirectoryURL?.standardizedFileURL.path == supportPath)
            #expect(await hostOrchestrator.store?.supportDirectoryURL?.standardizedFileURL.path == supportPath)

            // Every incarnation of a slot runs on the slot's runner.
            let a = try await host.newSession(in: first, sessionID: "a")
            let c = try await host.newSession(in: shared, sessionID: "c")
            #expect(a.runner === firstRunner)
            #expect((a.controller.managementRuntime as? AgentCoreSessionRunner) === firstRunner)
            #expect(c.runner === host.runner)
            #expect((c.controller.managementRuntime as? AgentCoreSessionRunner) === host.runner)
            let next = try await host.newSession(in: first, sessionID: "a-next")
            #expect(next.runner === firstRunner)

            await host.closeSlot(second)
            #expect(host.runner(in: second) == nil)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aDedicatedRunnerHasItsOwnAccessModeStartingStandard() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            #expect(await host.runner.toggleLocalExecAccessMode() == .fullAccess)
            let slot = try host.openSlot(environment.descriptor("dedicated", dedicated: true))
            let dedicated = try #require(host.runner(in: slot))

            #expect(await dedicated.localExecAccessMode() == .standard)
            await dedicated.setLocalExecAccessMode(.fullAccess)
            #expect(await dedicated.localExecAccessMode() == .fullAccess)
            await dedicated.setLocalExecAccessMode(.fullAccess)
            #expect(await dedicated.localExecAccessMode() == .fullAccess)
            await host.runner.setLocalExecAccessMode(.standard)
            #expect(await host.runner.localExecAccessMode() == .standard)
            #expect(await dedicated.localExecAccessMode() == .fullAccess)
            await dedicated.setLocalExecAccessMode(.standard)
            #expect(await dedicated.localExecAccessMode() == .standard)
            await host.shutdown()
        }
    }

    // MARK: - Isolation

    @Test
    nonisolated func aModelChangeInADedicatedSlotLeavesTheBackendAndSessionsOfAnotherSlotAlone() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let first = try host.openSlot(environment.descriptor("first", dedicated: true))
            let second = try host.openSlot(environment.descriptor("second", dedicated: true))
            let a = try await host.newSession(in: first, sessionID: "a")
            let b = try await host.newSession(in: second, sessionID: "b")
            try await a.controller.startInitialSession()
            try await b.controller.startInitialSession()
            let firstRunner = try #require(host.runner(in: first))
            let secondRunner = try #require(host.runner(in: second))
            let firstBackend = try #require(await Self.backend(of: firstRunner))
            let secondBackend = try #require(await Self.backend(of: secondRunner))
            #expect(firstBackend !== secondBackend)
            #expect(firstBackend.modelID == "model-a")
            #expect(secondBackend.modelID == "model-a")
            try await Self.runTurn("before", on: b)

            let outcome = try await a.controller.selectModel(id: "model-b")

            #expect(outcome.change == .sessionRecreated)
            // The first slot's runner built a new backend for the new model.
            #expect(await firstBackend.shutdownCount == 1)
            let replacement = try #require(await Self.backend(of: firstRunner))
            #expect(replacement !== firstBackend)
            #expect(replacement.modelID == "model-b")
            #expect(await replacement.sessionIDs() == ["a"])
            #expect(environment.backendLog.count == 3)
            // The second slot keeps its backend, its session, and its model.
            #expect(await secondBackend.shutdownCount == 0)
            #expect(await Self.backend(of: secondRunner) === secondBackend)
            #expect(await secondBackend.sessionIDs() == ["b"])
            #expect(await secondRunner.sessions["b"] != nil)
            #expect(await secondRunner.activeRuntimeConfiguration?.modelID == "model-a")
            try await Self.runTurn("after", on: b)
            #expect(await secondBackend.prompts == ["before", "after"])
            #expect(await secondBackend.shutdownCount == 0)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aClosedSessionIsDisposedOfOnItsOwnRunnerWhateverAnotherRunnerRuns() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let dedicatedSlot = try host.openSlot(environment.descriptor("dedicated", dedicated: true))
            let sharedSlot = try host.openSlot(environment.descriptor("shared", dedicated: false))
            // The same id on two runners: each is a session of its own runner.
            let onDedicated = try await host.newSession(in: dedicatedSlot, sessionID: "same")
            let onShared = try await host.newSession(in: sharedSlot, sessionID: "same")
            try await onDedicated.controller.startInitialSession()
            try await onShared.controller.startInitialSession()
            let dedicatedRunner = try #require(host.runner(in: dedicatedSlot))
            let dedicatedBackend = try #require(await Self.backend(of: dedicatedRunner))
            let hostBackend = try #require(await Self.backend(of: host.runner))

            await host.closeSession(in: sharedSlot)

            // The other slot runs the id on another runner: it does not keep
            // the host runner's session alive.
            #expect(await hostBackend.closedSessionIDs == ["same"])
            #expect(await host.runner.sessions["same"] == nil)
            #expect(await dedicatedBackend.closedSessionIDs.isEmpty)
            #expect(await dedicatedRunner.sessions["same"] != nil)
            await host.shutdown()
        }
    }

    // MARK: - Close and shutdown

    @Test
    nonisolated func closingADedicatedSlotShutsItsRunnerDownAndKeepsTheHostRunnerAndTheExternalTools() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let dedicatedSlot = try host.openSlot(environment.descriptor("dedicated", dedicated: true))
            let sharedSlot = try host.openSlot(environment.descriptor("shared", dedicated: false))
            let onDedicated = try await host.newSession(in: dedicatedSlot, sessionID: "dedicated")
            let onShared = try await host.newSession(in: sharedSlot, sessionID: "shared")
            try await onDedicated.controller.startInitialSession()
            try await onShared.controller.startInitialSession()
            let dedicatedRunner = try #require(host.runner(in: dedicatedSlot))
            let dedicatedBackend = try #require(await Self.backend(of: dedicatedRunner))
            let hostBackend = try #require(await Self.backend(of: host.runner))
            let mcpFence = await environment.mcpRuntime.shutdownFence()
            let dedicatedShutdowns = await dedicatedRunner.shutdownGeneration
            let hostShutdowns = await host.runner.shutdownGeneration
            #expect(host.telegramChannelCreatingIfNeeded(in: dedicatedSlot)?.sessionRunner === dedicatedRunner)
            #expect(host.telegramChannelCreatingIfNeeded(in: sharedSlot)?.sessionRunner === host.runner)

            await host.closeSlot(dedicatedSlot)

            #expect(host.runner(in: dedicatedSlot) == nil)
            #expect(host.dedicatedRunners.isEmpty)
            // Its session was closed, then its runner shut down.
            #expect(await dedicatedBackend.closedSessionIDs == ["dedicated"])
            #expect(await dedicatedBackend.shutdownCount == 1)
            #expect(await dedicatedRunner.shutdownGeneration != dedicatedShutdowns)
            // The host's runner, its session, and the external tools stay.
            #expect(await host.runner.shutdownGeneration == hostShutdowns)
            #expect(await hostBackend.shutdownCount == 0)
            #expect(await hostBackend.sessionIDs() == ["shared"])
            #expect(await environment.mcpRuntime.isActive(mcpFence))
            try await Self.runTurn("still here", on: onShared)
            #expect(await hostBackend.prompts == ["still here"])

            await host.shutdown()
            #expect(await hostBackend.shutdownCount == 1)
            #expect(await environment.mcpRuntime.isActive(mcpFence) == false)
            // The dedicated runner is shut down once.
            #expect(await dedicatedBackend.shutdownCount == 1)
        }
    }

    @Test
    nonisolated func theHostsShutdownShutsEveryDedicatedRunnerDownThenItsOwn() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let first = try host.openSlot(environment.descriptor("first", dedicated: true))
            let second = try host.openSlot(environment.descriptor("second", dedicated: true))
            let shared = try host.openSlot(environment.descriptor("shared", dedicated: false))
            for (slot, sessionID) in [(first, "first"), (second, "second"), (shared, "shared")] {
                let incarnation = try await host.newSession(in: slot, sessionID: sessionID)
                try await incarnation.controller.startInitialSession()
            }
            let runners = try [first, second].map { try #require(host.runner(in: $0)) }
            var backends: [DedicatedRunnerTestBackend] = []
            for runner in runners + [host.runner] {
                backends.append(try #require(await Self.backend(of: runner)))
            }
            var generations: [UInt64] = []
            for runner in runners + [host.runner] {
                generations.append(await runner.shutdownGeneration)
            }
            let mcpFence = await environment.mcpRuntime.shutdownFence()

            await host.shutdown()

            #expect(host.dedicatedRunners.isEmpty)
            for (index, runner) in (runners + [host.runner]).enumerated() {
                #expect(await backends[index].shutdownCount == 1)
                #expect(await runner.shutdownGeneration != generations[index])
            }
            #expect(await environment.mcpRuntime.isActive(mcpFence) == false)
            // A second shutdown does nothing more.
            await host.shutdown()
            for backend in backends {
                #expect(await backend.shutdownCount == 1)
            }
        }
    }

    // MARK: - Delegated tool events

    @Test
    nonisolated func delegatedToolEventsReachOnlyTheSlotsOfTheirRunner() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let dedicatedPresenter = ToolEventRecordingPresenter()
            let sharedPresenter = ToolEventRecordingPresenter()
            let dedicatedSlot = try host.openSlot(
                environment.descriptor("dedicated", dedicated: true, presenter: dedicatedPresenter)
            )
            let sharedSlot = try host.openSlot(
                environment.descriptor("shared", dedicated: false, presenter: sharedPresenter)
            )
            // The same root session id on two runners.
            let onDedicated = try await host.newSession(in: dedicatedSlot, sessionID: "root")
            let onShared = try await host.newSession(in: sharedSlot, sessionID: "root")
            let dedicatedRunner = try #require(host.runner(in: dedicatedSlot))

            // A hosted turn installs the router on its slot's runner only.
            try await Self.runTurn("Hello", on: onDedicated)
            let dedicatedBackend = try #require(await Self.backend(of: dedicatedRunner))
            #expect(await dedicatedBackend.hasSubAgentToolEventHandler())
            #expect(host.subAgentToolEventRoutingSlots == [dedicatedSlot])
            #expect(host.isRoutingSubAgentToolEvents == false)
            try await Self.runTurn("Hello", on: onShared)
            let hostBackend = try #require(await Self.backend(of: host.runner))
            #expect(await hostBackend.hasSubAgentToolEventHandler())
            #expect(host.isRoutingSubAgentToolEvents)

            await dedicatedBackend.emit(DirectSubAgentToolEvent(
                agentID: "dedicated-worker", agentName: "dedicated-worker", toolCall: Self.readCall("one"),
                lifecycle: .started, rootSessionID: "root"
            ))
            await hostBackend.emit(DirectSubAgentToolEvent(
                agentID: "shared-worker", agentName: "shared-worker", toolCall: Self.readCall("two"),
                lifecycle: .started, rootSessionID: "root"
            ))
            #expect(await dedicatedPresenter.events == ["dedicated-worker:one"])
            #expect(await sharedPresenter.events == ["shared-worker:two"])

            // Without a root session, the event's own runner's snapshots
            // decide: the host runner does not know the dedicated agent.
            await dedicatedBackend.setSubAgentSnapshots([Self.agentSnapshot(id: "known", rootSessionID: "root")])
            await hostBackend.emit(DirectSubAgentToolEvent(
                agentID: "known", agentName: "known", toolCall: Self.readCall("three"), lifecycle: .started
            ))
            await dedicatedBackend.emit(DirectSubAgentToolEvent(
                agentID: "known", agentName: "known", toolCall: Self.readCall("four"), lifecycle: .started
            ))
            #expect(await dedicatedPresenter.events == ["dedicated-worker:one", "known:four"])
            #expect(await sharedPresenter.events == ["shared-worker:two"])

            // A closed slot's runner routes to nobody, and leaves the other
            // runner's routing alone.
            await host.closeSlot(dedicatedSlot)
            #expect(host.subAgentToolEventRoutingSlots.isEmpty)
            await dedicatedBackend.emit(DirectSubAgentToolEvent(
                agentID: "dedicated-worker", agentName: "dedicated-worker", toolCall: Self.readCall("five"),
                lifecycle: .started, rootSessionID: "root"
            ))
            await hostBackend.emit(DirectSubAgentToolEvent(
                agentID: "shared-worker", agentName: "shared-worker", toolCall: Self.readCall("six"),
                lifecycle: .started, rootSessionID: "root"
            ))
            #expect(await dedicatedPresenter.events == ["dedicated-worker:one", "known:four"])
            #expect(await sharedPresenter.events == ["shared-worker:two", "shared-worker:six"])
            await host.shutdown()
        }
    }
}
