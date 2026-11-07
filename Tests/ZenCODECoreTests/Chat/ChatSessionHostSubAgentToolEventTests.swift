//
//  ChatSessionHostSubAgentToolEventTests.swift
//  ZenCODE
//
//  The host's routing of the delegated sub-agents' tool events: the router a
//  hosted turn installs on the runner, the event that reaches the controller
//  of the slot running the agent's root session (every such slot, by epoch),
//  the live artifact a completed call records in the running turn before it
//  ends, the baseline a started call captures for the turn's summary, the
//  presenter an event and its overview are presented on (the turn's, the
//  controller's once the turn was cancelled), the root session read from the
//  runner's snapshots when the event has none, the slot skipped when it
//  stopped running the session during an earlier delivery, and the events
//  dropped for an unknown session or a host shut down. Every
//  test runs in directories named by UUIDs; nothing touches the real
//  application state.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Records, as `<name>:<agent>:<call>:<phase>`, the delegated tool events a
/// slot's presenter receives, in a log several presenters may share, and,
/// when asked, the sub-agent overviews it receives as `<name>:overview`.
private actor DelegatedToolEventPresenter: ChatSessionPresenter {
    nonisolated let name: String
    nonisolated let log: SharedDeliveryLog?
    nonisolated let logsOverviews: Bool
    private(set) var events: [String] = []
    /// Runs, on the chat actor, once the first event is recorded, before the
    /// presentation returns: what happens while the router is suspended in
    /// this delivery.
    private var onFirstEvent: (@Sendable @ChatSessionActor () async -> Void)?

    init(name: String, log: SharedDeliveryLog? = nil, logsOverviews: Bool = false) {
        self.name = name
        self.log = log
        self.logsOverviews = logsOverviews
    }

    func presentSubAgentToolEvent(_ event: DirectSubAgentToolEvent) async {
        let phase: String
        switch event.lifecycle {
        case .started: phase = "started"
        case .completed: phase = "completed"
        }
        let entry = "\(event.agentID):\(event.toolCall.id):\(phase)"
        events.append(entry)
        log?.entries.withLock { $0.append("\(name):\(entry)") }
        if let hook = onFirstEvent {
            onFirstEvent = nil
            await hook()
        }
    }

    func presentSubAgentOverview(
        _ overview: ChatSubAgentOverview,
        origin: ChatOverviewOrigin,
        publication: ChatOverviewPublication?
    ) async {
        guard logsOverviews else { return }
        log?.entries.withLock { $0.append("\(name):overview") }
    }
}

/// A shared log for presenters that must be compared in delivery order.
private final class SharedDeliveryLog: Sendable {
    let entries = Mutex<[String]>([])
}

/// A runtime backend whose turn runs a script with the sub-agent tool event
/// handler the runner handed it, and whose sub-agent snapshots are set by
/// the test.
private actor RoutingTestBackend: AgentRuntimeBackend {
    typealias Script = @Sendable @ChatSessionActor (
        _ sessionID: String,
        _ handler: DirectSubAgentToolEventHandler?
    ) async throws -> Void

    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var handler: DirectSubAgentToolEventHandler?
    private var script: Script?
    private var snapshots: [DirectSubAgentRuntime.AgentSnapshot] = []

    func setScript(_ script: Script?) {
        self.script = script
    }

    func setSubAgentSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        self.snapshots = snapshots
    }

    func hasSubAgentToolEventHandler() -> Bool {
        handler != nil
    }

    /// Emits `event` through the handler, as a sub-agent outside a turn does.
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
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
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
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }

    func sendPrompt(
        sessionID: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if let script {
            try await script(sessionID, handler)
        }
        await onEvent(.content("done"))
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }
}

/// A value the chat actor reads and writes from the scripts of a turn.
@ChatSessionActor
private final class Box<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}

@ChatSessionActor
@Suite("Chat session host sub-agent tool events", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionHostSubAgentToolEventTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let backend = RoutingTestBackend()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-chat-host-routing-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        @ChatSessionActor
        func makeHost() throws -> ChatSessionHost {
            let backend = backend
            let runner = AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: workspace
            )
            return ChatSessionHost(
                runner: runner,
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE chat host routing test"
            )
        }

        /// A slot that publishes state, presenting on `presenter`.
        @ChatSessionActor
        func descriptor(_ name: String, presenter: DelegatedToolEventPresenter) -> ChatSlotDescriptor {
            ChatSlotDescriptor(
                identity: .window(name),
                workingDirectory: workspace,
                presenter: presenter,
                interaction: .pendingRequests(capabilities: [.textInput]),
                authorizer: ChatToolConsentAuthorizer(
                    host: ScriptedChatInteractionHost(capabilities: [], decisions: [])
                ),
                defaultOrigin: .app,
                publishesState: true
            )
        }
    }

    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.chat-host-sub-agent-routing") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    private static func runTurn(
        _ prompt: String,
        on incarnation: ChatSessionIncarnation
    ) async throws -> ChatTurnResult {
        let controller = incarnation.controller
        return try await controller.runTurn(
            ChatTurnRequest(
                prompt: prompt,
                sessionConfiguration: await controller.currentSessionConfiguration(responseLanguageSection: nil)
            )
        )
    }

    private static func call(_ id: String, name: String = "local.writeFile", path: String) -> DirectAgentToolCall {
        DirectAgentToolCall(id: id, name: name, argumentsObject: ["path": path], argumentsJSON: "{}")
    }

    /// The live artifacts of `reducer`'s log, as agent and paths.
    private static func liveArtifacts(of reducer: ChatSessionStateReducer) -> [(agentID: String?, paths: [String])] {
        reducer.snapshot.fileChanges.artifactHistory.compactMap { entry in
            guard case let .fileArtifacts(turn, agentID, isSealed) = entry.kind, !isSealed else { return nil }
            return (agentID, turn.artifacts.map(\.displayPath))
        }
    }

    // MARK: - Routing during a turn

    @Test
    nonisolated func aRoutedDelegatedCompletionIsLiveInTheRunningTurnAndItsStartCapturesTheBaseline() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let presenterA = DelegatedToolEventPresenter(name: "a")
            let presenterB = DelegatedToolEventPresenter(name: "b")
            let slotA = try host.openSlot(environment.descriptor("a", presenter: presenterA))
            let slotB = try host.openSlot(environment.descriptor("b", presenter: presenterB))
            let a = try await host.newSession(in: slotA, sessionID: "root-a")
            let b = try await host.newSession(in: slotB, sessionID: "root-b")
            let reducerA = try #require(a.reducer)
            let reducerB = try #require(b.reducer)
            let file = environment.workspace.appendingPathComponent("Delegated.swift")
            let before = Data("let value = 1\n".utf8)
            try before.write(to: file)
            let write = Self.call("write", path: "Delegated.swift")
            let read = Self.call("read", name: "local.readFile", path: "Other.swift")
            let liveDuringTurn = Box<[(agentID: String?, paths: [String])]>([])
            let otherSlotLiveDuringTurn = Box<Int>(-1)
            await environment.backend.setScript { sessionID, handler in
                let handler = try #require(handler)
                #expect(sessionID == "root-a")
                await handler(DirectSubAgentToolEvent(
                    agentID: "worker", agentName: "worker", toolCall: write,
                    lifecycle: .started, rootSessionID: sessionID
                ))
                try Data("let value = 2\n".utf8).write(to: file)
                await handler(DirectSubAgentToolEvent(
                    agentID: "worker", agentName: "worker", toolCall: write,
                    lifecycle: .completed(DirectAgentToolResult(
                        output: "Updated", summary: "Updated",
                        fileChanges: [OperationFileChange(
                            path: "Delegated.swift", oldText: "let value = 1\n", newText: "let value = 2\n"
                        )]
                    )),
                    rootSessionID: sessionID
                ))
                // Still inside the model request: the artifact is live.
                liveDuringTurn.value = Self.liveArtifacts(of: reducerA)
                // The other slot's session gets its own event, and an
                // unknown session gets nothing.
                await handler(DirectSubAgentToolEvent(
                    agentID: "other", agentName: "other", toolCall: read,
                    lifecycle: .completed(DirectAgentToolResult(
                        output: "Updated", summary: "Updated",
                        fileChanges: [OperationFileChange(path: "Other.swift", oldText: nil, newText: "x\n")]
                    )),
                    rootSessionID: "root-b"
                ))
                await handler(DirectSubAgentToolEvent(
                    agentID: "ghost", agentName: "ghost", toolCall: read,
                    lifecycle: .started, rootSessionID: "unknown-root"
                ))
                otherSlotLiveDuringTurn.value = Self.liveArtifacts(of: reducerB).count
            }

            let result = try await Self.runTurn("Delegate", on: a)

            #expect(liveDuringTurn.value.count == 1)
            #expect(liveDuringTurn.value.first?.agentID == "worker")
            #expect(liveDuringTurn.value.first?.paths == ["Delegated.swift"])
            // The other slot runs no turn: it presents the event but records
            // no artifact.
            #expect(otherSlotLiveDuringTurn.value == 0)
            #expect(await presenterA.events == ["worker:write:started", "worker:write:completed"])
            #expect(await presenterB.events == ["other:read:completed"])
            // The started call captured the file before the agent wrote it.
            let summary = try #require(result.fileChangeSummary)
            let entry = try #require(summary.entries.first { $0.path == "Delegated.swift" })
            #expect(entry.beforeDataBase64 == before.base64EncodedString())
            #expect(entry.status == .modified)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func everySlotRunningTheRootSessionReceivesTheEventInEpochOrder() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let log = SharedDeliveryLog()
            let running = DelegatedToolEventPresenter(name: "running", log: log)
            let idle = DelegatedToolEventPresenter(name: "idle", log: log)
            let runningSlot = try host.openSlot(environment.descriptor("running", presenter: running))
            let idleSlot = try host.openSlot(environment.descriptor("idle", presenter: idle))
            // The idle slot's incarnation is older: it is presented first.
            let idleIncarnation = try await host.newSession(in: idleSlot, sessionID: "shared-root")
            let runningIncarnation = try await host.newSession(in: runningSlot, sessionID: "shared-root")
            #expect(idleIncarnation.epoch < runningIncarnation.epoch)
            let write = Self.call("write", path: "Shared.swift")
            await environment.backend.setScript { sessionID, handler in
                let handler = try #require(handler)
                await handler(DirectSubAgentToolEvent(
                    agentID: "worker", agentName: "worker", toolCall: write,
                    lifecycle: .completed(DirectAgentToolResult(
                        output: "Updated", summary: "Updated",
                        fileChanges: [OperationFileChange(path: "Shared.swift", oldText: nil, newText: "shared\n")]
                    )),
                    rootSessionID: sessionID
                ))
            }

            _ = try await Self.runTurn("Delegate", on: runningIncarnation)

            #expect(log.entries.withLock { $0 } == [
                "idle:worker:write:completed",
                "running:worker:write:completed",
            ])
            // Only the controller with the recording turn records the artifact.
            let runningLive = Self.liveArtifacts(of: try #require(runningIncarnation.reducer))
            #expect(runningLive.map(\.agentID) == ["worker"])
            #expect(runningLive.first?.paths == ["Shared.swift"])
            #expect(Self.liveArtifacts(of: try #require(idleIncarnation.reducer)).isEmpty)
            await host.shutdown()
        }
    }

    // MARK: - Routing outside a turn

    @Test
    nonisolated func anEventWithoutRootSessionIsRoutedByTheRunnersSnapshotsAndDroppedOtherwise() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let presenter = DelegatedToolEventPresenter(name: "slot")
            let slot = try host.openSlot(environment.descriptor("slot", presenter: presenter))
            let incarnation = try await host.newSession(in: slot, sessionID: "root")
            // A hosted turn installs the router before its model request.
            #expect(await environment.backend.hasSubAgentToolEventHandler() == false)
            _ = try await Self.runTurn("Hello", on: incarnation)
            #expect(await environment.backend.hasSubAgentToolEventHandler())
            await environment.backend.setSubAgentSnapshots([
                DirectSubAgentRuntime.AgentSnapshot(
                    id: "known", rootSessionID: "root", name: "Known", role: "Worker", status: .running,
                    pending: true, latestOutput: nil, executionRevision: 1,
                    completedExecutionRevision: 0, latestOutputRevision: 0, latestError: nil,
                    createdAt: .now, updatedAt: .now
                ),
                DirectSubAgentRuntime.AgentSnapshot(
                    id: "elsewhere", rootSessionID: "another-root", name: "Elsewhere", role: "Worker",
                    status: .running, pending: true, latestOutput: nil, executionRevision: 1,
                    completedExecutionRevision: 0, latestOutputRevision: 0, latestError: nil,
                    createdAt: .now, updatedAt: .now
                ),
            ])
            let read = Self.call("read", name: "local.readFile", path: "a.swift")
            for agentID in ["known", "elsewhere", "unknown"] {
                await environment.backend.emit(DirectSubAgentToolEvent(
                    agentID: agentID, agentName: agentID, toolCall: read, lifecycle: .started
                ))
            }
            #expect(await presenter.events == ["known:read:started"])

            // A host shut down routes nothing more.
            await host.shutdown()
            await environment.backend.emit(DirectSubAgentToolEvent(
                agentID: "known", agentName: "known", toolCall: read,
                lifecycle: .completed(DirectAgentToolResult(output: "ok", summary: "ok")),
                rootSessionID: "root"
            ))
            #expect(await presenter.events == ["known:read:started"])
        }
    }
}
