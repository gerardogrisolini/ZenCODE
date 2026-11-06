//
//  AgentCoreBackendDS4LifecycleTests.swift
//  ZenCODE
//
//  Engine lifecycle around the agent backends (decision A). Closing a backend
//  releases only its DS4 sessions and the model stays loaded. The engine is
//  closed when a non-DS4 root backend is prepared while no DS4 session is
//  live, and when the session runner shuts down (`zen` exit). Every test uses
//  a private registry over `MockDS4Engine`; no model is loaded.
//

import Foundation
import Testing
@testable import ZenCODECore

/// A non-DS4 root backend (a remote provider or a subscription client). It
/// only answers prompts; these tests look at the engine, not at its output.
private actor RemoteStandInBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?,
                       allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        sessions[id] = AgentRuntimeSessionSnapshot(sessionID: id, workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history, allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage], cacheKey: String?,
                              allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        if sessions[id] == nil {
            createSession(id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
                allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
        }
    }
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
                              thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) async { sessions.removeValue(forKey: id) }
    func shutdown() async { sessions.removeAll() }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "remote-model" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { sessions[id] }
    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
                    onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        .init(text: "remote response", stopReason: "stop", modelID: "remote-model")
    }
}

@Suite
struct AgentCoreBackendDS4LifecycleTests {
    @Test
    func preparingANonDS4BackendClosesAnIdleDS4Engine() async throws {
        let harness = try DS4ClientHarness()
        _ = try await harness.registry.engine(for: harness.configuration)
        let core = AgentCoreBackend(
            configuration: harness.runtimeConfiguration(),
            backendFactory: { _, _ in RemoteStandInBackend() },
            ds4EngineRegistry: harness.registry
        )

        let loaded = try await core.preloadModel { _ in }

        #expect(loaded == "remote-model")
        #expect(await harness.registry.currentIdentity == nil)
        #expect(harness.mock.isClosed)
        #expect(harness.openCount == 1)
        await core.shutdown()
    }

    @Test
    func preparingANonDS4BackendKeepsTheEngineWhileADS4SessionIsLive() async throws {
        let harness = try DS4ClientHarness()
        let engine = try await harness.registry.engine(for: harness.configuration)
        _ = try await engine.sync(sessionID: "live", transcript: [.begin], onProgress: { _, _, _ in })
        let core = AgentCoreBackend(
            configuration: harness.runtimeConfiguration(),
            backendFactory: { _, _ in RemoteStandInBackend() },
            ds4EngineRegistry: harness.registry
        )

        _ = try await core.preloadModel { _ in }

        #expect(await harness.registry.currentIdentity == harness.configuration.identity)
        #expect(!harness.mock.isClosed)
        #expect(harness.mock.liveSessionIDs == ["live"])
        #expect(harness.openCount == 1)
        await core.shutdown()
    }

    @Test
    func preparingADS4ClientBackendLeavesTheEngineOpen() async throws {
        let harness = try DS4ClientHarness()
        _ = try await harness.registry.engine(for: harness.configuration)
        let client = try await harness.makeClient()
        let core = AgentCoreBackend(
            configuration: harness.runtimeConfiguration(),
            backendFactory: { _, _ in client },
            ds4EngineRegistry: harness.registry
        )

        _ = try await core.preloadModel { _ in }

        #expect(await harness.registry.currentIdentity == harness.configuration.identity)
        #expect(!harness.mock.isClosed)
        #expect(harness.openCount == 1)
        await core.shutdown()
    }

    @Test
    func shuttingDownADS4BackendReleasesItsSessionsAndKeepsTheEngineForTheNextAgent() async throws {
        let harness = try DS4ClientHarness()
        let first = try await harness.makeClient(sessionID: "session")
        let firstCore = AgentCoreBackend(
            configuration: harness.runtimeConfiguration(),
            backendFactory: { _, _ in first },
            ds4EngineRegistry: harness.registry
        )
        _ = try await firstCore.sendPrompt(sessionID: "session", prompt: "first", onEvent: { _ in })
        #expect(harness.mock.liveSessionIDs == ["session"])

        await firstCore.shutdown()

        #expect(harness.mock.liveSessionIDs.isEmpty)
        #expect(!harness.mock.isClosed)
        #expect(await harness.registry.currentIdentity == harness.configuration.identity)

        let second = try await harness.makeClient(sessionID: "next-agent")
        let secondCore = AgentCoreBackend(
            configuration: harness.runtimeConfiguration(),
            backendFactory: { _, _ in second },
            ds4EngineRegistry: harness.registry
        )
        _ = try await secondCore.sendPrompt(sessionID: "next-agent", prompt: "second", onEvent: { _ in })

        #expect(harness.openCount == 1)
        #expect(harness.mock.liveSessionIDs == ["next-agent"])
        await secondCore.shutdown()
    }
}

@Suite
struct AgentCoreSessionRunnerDS4LifecycleTests {
    @Test
    func runnerShutdownClosesAnIdleDS4Engine() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        _ = try await registry.engine(for: .mock())
        let runner = AgentCoreSessionRunner(
            taskGraphStore: nil,
            sessionTurnLease: AgentSessionTurnLease(),
            memoryGraphStoreRegistry: MemoryGraphStoreRegistry(),
            ds4EngineRegistry: registry
        )

        await runner.shutdown()

        #expect(await registry.currentIdentity == nil)
        #expect(factory.engines.first?.isClosed == true)
    }

    @Test
    func runnerShutdownKeepsTheEngineWhileAnotherRunnerHoldsADS4Session() async throws {
        let factory = MockDS4EngineFactory()
        let registry = DS4EngineRegistry(factory: factory.factory)
        let engine = try await registry.engine(for: .mock())
        _ = try await engine.sync(sessionID: "other-runner", transcript: [.begin], onProgress: { _, _, _ in })
        let runner = AgentCoreSessionRunner(
            taskGraphStore: nil,
            sessionTurnLease: AgentSessionTurnLease(),
            memoryGraphStoreRegistry: MemoryGraphStoreRegistry(),
            ds4EngineRegistry: registry
        )

        await runner.shutdown()

        #expect(await registry.currentIdentity == DS4EngineConfiguration.mock().identity)
        #expect(factory.engines.first?.isClosed == false)
    }

    @Test
    func runnerShutdownReleasesTheDS4SessionBeforeClosingTheEngine() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient(sessionID: "root")
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in client },
            taskGraphStore: nil,
            sessionTurnLease: AgentSessionTurnLease(),
            memoryGraphStoreRegistry: MemoryGraphStoreRegistry(),
            ds4EngineRegistry: harness.registry
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "root",
            modelID: harness.provider.modelID,
            workingDirectory: harness.base,
            systemPrompt: DS4ClientHarness.systemPrompt,
            cacheKey: nil,
            history: [],
            allowedToolNames: [DS4ClientHarness.toolName]
        )
        _ = try await runner.sendPrompt(configuration: configuration, prompt: "hi", attachments: [], onEvent: { _ in })
        #expect(harness.mock.liveSessionIDs == ["root"])

        await runner.shutdown()

        let calls = harness.mock.calls
        let released = try #require(calls.firstIndex(of: .releaseSession("root")))
        let closed = try #require(calls.firstIndex(of: .close))
        #expect(released < closed)
        #expect(harness.mock.isClosed)
        #expect(await harness.registry.currentIdentity == nil)
    }

    /// The terminal sends the manifest model id (`ds4:…`) while the DS4
    /// client reports its wire id (`deepseek-v4-flash`) in the snapshot. The
    /// stored configuration must keep the manifest id: otherwise the next turn
    /// fails `matchesRuntime`, the session is recreated without its `ds4_`
    /// keys and the whole prompt is prefilled again.
    @Test
    func aSecondPromptReusesTheKVWhenTheManifestIDDiffersFromTheWireID() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient(sessionID: "root")
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in client },
            taskGraphStore: nil,
            sessionTurnLease: AgentSessionTurnLease(),
            memoryGraphStoreRegistry: MemoryGraphStoreRegistry(),
            ds4EngineRegistry: harness.registry
        )
        let configuration = AgentCoreSessionConfiguration(
            sessionID: "root",
            modelID: "ds4:mock-q2",
            workingDirectory: harness.base,
            systemPrompt: DS4ClientHarness.systemPrompt,
            cacheKey: "root",
            history: [],
            allowedToolNames: [DS4ClientHarness.toolName]
        )
        #expect(configuration.modelID != harness.provider.modelID)

        _ = try await runner.sendPrompt(configuration: configuration, prompt: "hi", attachments: [], onEvent: { _ in })
        let snapshot = try #require(await runner.snapshotSession(id: "root"))
        #expect(snapshot.modelID == harness.provider.modelID)
        // The next turn, as the terminal composes it: same selection, history
        // from the snapshot of the turn that ended.
        let next = AgentCoreSessionConfiguration(
            sessionID: "root",
            modelID: "ds4:mock-q2",
            workingDirectory: harness.base,
            systemPrompt: DS4ClientHarness.systemPrompt,
            cacheKey: "root",
            history: snapshot.history,
            allowedToolNames: [DS4ClientHarness.toolName]
        )
        _ = try await runner.sendPrompt(configuration: next, prompt: "again", attachments: [], onEvent: { _ in })

        let syncs = harness.engine.syncs
        try #require(syncs.count == 2)
        let generated = try #require(harness.engine.results.first).tokens.count
        #expect(generated > 0)
        // Round 2 reuses the whole first prompt and the tokens round 1 generated.
        #expect(syncs[0].cached == 0)
        #expect(syncs[1].cached == syncs[0].suffix + generated)
        #expect(harness.mock.liveSessionIDs == ["root"])
        #expect(!harness.mock.calls.contains(.releaseSession("root")))

        await runner.shutdown()
    }
}
