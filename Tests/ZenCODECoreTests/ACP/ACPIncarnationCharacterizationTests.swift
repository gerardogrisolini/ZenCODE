//
//  ACPIncarnationCharacterizationTests.swift
//  ZenCODE
//
//  Characterization of the session-incarnation contract of the ACP bridge,
//  written before the container (`ChatSessionHost`) took the incarnations,
//  the prompt reservation, and the epochs over: epochs grow and are never
//  reused, work of an older incarnation never touches a replacement with the
//  same id, cancel and close act on one session only, and a prompt and a
//  reconfiguration exclude each other.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Records every JSON-RPC message the bridge writes.
private final class IncarnationTransport: Sendable {
    private let messages = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            guard let text = String(data: data, encoding: .utf8) else {
                return
            }
            self.messages.withLock { $0.append(text) }
        }
    }

    private var decoded: [[String: Any]] {
        messages.withLock { $0 }.compactMap { text in
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return object as? [String: Any]
        }
    }

    /// The responses to request `id`.
    func responses(id: Int) -> [[String: Any]] {
        decoded.filter { message in
            guard message["method"] == nil, let rawID = message["id"] as? NSNumber else {
                return false
            }
            return rawID.intValue == id
        }
    }

    func stopReason(id: Int) -> String? {
        responses(id: id).first.flatMap { ($0["result"] as? [String: Any])?["stopReason"] as? String }
    }
}

/// A backend whose prompts can be pinned by the text they carry and whose
/// `shutdown()` (the runner's backend teardown, forced by a model switch)
/// can be pinned too, so the races below are deterministic.
private actor IncarnationBackend: AgentRuntimeBackend {
    struct PromptPin {
        let started = ACPLifecycleGate()
        let finish = ACPLifecycleGate()
    }

    private var pins: [String: PromptPin] = [:]
    private var shutdownReached: ACPLifecycleGate?
    private var shutdownRelease: ACPLifecycleGate?
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private(set) var prompts: [String] = []

    /// Pins every prompt whose text contains `needle`: `started` opens when
    /// the prompt reaches the backend, which returns once `finish` opens or
    /// the turn is cancelled.
    func pin(_ needle: String) -> PromptPin {
        let pin = PromptPin()
        pins[needle] = pin
        return pin
    }

    /// Pins the next `shutdown()`: `reached` opens when it is entered, and
    /// it returns once `release` opens.
    func pinShutdown() -> (reached: ACPLifecycleGate, release: ACPLifecycleGate) {
        let gates = (reached: ACPLifecycleGate(), release: ACPLifecycleGate())
        shutdownReached = gates.reached
        shutdownRelease = gates.release
        return gates
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        if let shutdownReached, let shutdownRelease {
            self.shutdownReached = nil
            self.shutdownRelease = nil
            shutdownReached.open()
            await shutdownRelease.wait()
        }
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        if let pin = pins.first(where: { prompt.contains($0.key) })?.value {
            pin.started.open()
            try await pin.finish.waitCancelling()
            try Task.checkCancellation()
        }
        return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

private extension ZenCODEACPBridge {
    /// Replaces the live incarnation of `configuration.sessionID` with a new,
    /// idle one, as a close followed by a load of the same id leaves it.
    func replaceIncarnationForTesting(_ configuration: AgentCoreSessionConfiguration) async throws {
        _ = try await installSession(configuration: configuration)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ACPIncarnationCharacterizationTests {
    private static func makeBridge(
        transport: IncarnationTransport = IncarnationTransport(),
        backend: IncarnationBackend
    ) throws -> ZenCODEACPBridge {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model"),
                AgentSettingsModelManifest(id: "other-model", kind: .remoteAPI, modelID: "local/other-model")
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        return ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: transport.sink),
            backendFactory: { _, _ in backend }
        )
    }

    private static func sessionParams(sessionID: String? = nil) -> [String: Any] {
        var params: [String: Any] = [
            "cwd": FileManager.default.temporaryDirectory.path,
            "allowedTools": [String]()
        ]
        if let sessionID {
            params["sessionId"] = sessionID
        }
        return params
    }

    private static func makeConfiguration(sessionID: String) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: [],
            allowedToolNames: []
        )
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async {
        for _ in 0 ..< 2_000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - Epochs

    @Test
    func epochsGrowAcrossSessionsAndAcrossRecreationsOfTheSameIDAndAreNeverReused() async throws {
        let bridge = try Self.makeBridge(backend: IncarnationBackend())

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let first = try #require(await bridge.testAnySessionID())
        let firstEpoch = try #require(await bridge.testSessionEpoch(sessionID: first))

        try await bridge.newSession(id: .number(2), params: Self.sessionParams())
        let second = try #require(await bridge.testSessionIDs().first { $0 != first })
        let secondEpoch = try #require(await bridge.testSessionEpoch(sessionID: second))
        #expect(secondEpoch > firstEpoch)

        // `session/load` of a closed id is a new incarnation of that id.
        try await bridge.close(id: .number(3), params: ["sessionId": first])
        try await bridge.loadSession(id: .number(4), params: Self.sessionParams(sessionID: first))
        let loadedEpoch = try #require(await bridge.testSessionEpoch(sessionID: first))
        #expect(loadedEpoch > secondEpoch)

        // So is `session/resume`, and the closed epochs are never handed out again.
        try await bridge.close(id: .number(5), params: ["sessionId": first])
        try await bridge.resumeSession(id: .number(6), params: Self.sessionParams(sessionID: first))
        let resumedEpoch = try #require(await bridge.testSessionEpoch(sessionID: first))
        #expect(resumedEpoch > loadedEpoch)
        #expect(Set([firstEpoch, secondEpoch, loadedEpoch, resumedEpoch]).count == 4)
        // The other session kept its incarnation throughout.
        #expect(await bridge.testSessionEpoch(sessionID: second) == secondEpoch)

        await bridge.shutdown()
    }

    // MARK: - Work of an older incarnation

    @Test
    func aLateTurnOfAReplacedIncarnationNeitherReleasesNorRewritesTheReplacementWithTheSameID() async throws {
        // The runner serializes the turns of one session id, so the turn of a
        // replacement incarnation starts only once the older turn's backend
        // call returned; everything the older ACP handler does after that
        // (snapshot refresh, reservation release, final reply) interleaves
        // with the replacement's reservation and must be fenced by the epoch.
        // The replacement is installed directly, as a close followed by a
        // load of the same id would leave it, and with another model so a
        // write-through of the older refresh would be visible.
        let transport = IncarnationTransport()
        let backend = IncarnationBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)
        let sessionID = "acp-incarnation-\(UUID().uuidString)"
        await bridge.installTestSession(Self.makeConfiguration(sessionID: sessionID))
        let oldPin = await backend.pin("old turn")
        let newPin = await backend.pin("new turn")

        let oldPrompt = Task {
            try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": "old turn"])
        }
        await oldPin.started.wait()
        let oldEpoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))
        let oldPromptID = try #require(await bridge.testActivePromptID(sessionID: sessionID))

        try await bridge.replaceIncarnationForTesting(
            Self.makeConfiguration(sessionID: sessionID).withModelID("other-model")
        )
        let newEpoch = try #require(await bridge.testSessionEpoch(sessionID: sessionID))
        #expect(newEpoch > oldEpoch)
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)

        // The replacement reserves its own prompt, which then queues on the
        // runner behind the older turn.
        let newPrompt = Task {
            try await bridge.prompt(id: .number(3), params: ["sessionId": sessionID, "prompt": "new turn"])
        }
        await Self.waitUntil { await bridge.testActivePromptID(sessionID: sessionID) != nil }
        let newPromptID = try #require(await bridge.testActivePromptID(sessionID: sessionID))
        #expect(newPromptID != oldPromptID)

        // The older turn ends now and its handler unwinds against the replacement.
        oldPin.finish.open()
        try await oldPrompt.value
        await newPin.started.wait()

        #expect(await bridge.testActivePromptID(sessionID: sessionID) == newPromptID)
        #expect(await bridge.testSessionEpoch(sessionID: sessionID) == newEpoch)
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "other-model")
        await #expect(throws: ACPError.self) {
            try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "third"])
        }

        newPin.finish.open()
        try await newPrompt.value
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)
        #expect(transport.stopReason(id: 1) == "end_turn")
        #expect(transport.stopReason(id: 3) == "end_turn")
        #expect(await backend.prompts.filter { $0.contains("turn") }.count == 2)

        await bridge.shutdown()
    }

    @Test
    func aStaleSetModelOfAClosedIncarnationDoesNotReconfigureTheReplacementWithTheSameID() async throws {
        let transport = IncarnationTransport()
        let backend = IncarnationBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        // Resolve the runtime backend so the model switch really tears one down.
        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "warm up"])
        let teardown = await backend.pinShutdown()

        let setModel = Task {
            try await bridge.setModel(id: .number(3), params: ["sessionId": sessionID, "modelId": "other-model"])
        }
        await teardown.reached.wait()

        try await bridge.close(id: .number(4), params: ["sessionId": sessionID])
        // The replacement incarnation of the same id (the runner is still
        // held by the pinned teardown, so it is installed directly).
        await bridge.installTestSession(Self.makeConfiguration(sessionID: sessionID))
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "test-model")

        teardown.release.open()
        _ = try? await setModel.value

        // The stale set neither answered nor reconfigured the replacement,
        // which keeps answering prompts.
        #expect(transport.responses(id: 3).isEmpty)
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "test-model")
        #expect(await bridge.testHasSession(sessionID: sessionID))
        try await bridge.prompt(id: .number(6), params: ["sessionId": sessionID, "prompt": "after"])
        #expect(transport.stopReason(id: 6) == "end_turn")

        await bridge.shutdown()
    }

    // MARK: - Prompt and reconfiguration exclude each other

    /// Fixed with the container (see `CHANGELOG.md`): `session/cancel` is
    /// the cancellation of a prompt, so a reconfiguration suspended in the
    /// runner keeps its reservation and answers normally once it commits.
    /// Before, the cancel also dropped the `.reconfiguring` state, and the
    /// `set_model` ended without any reply and without a rollback.
    @Test
    func cancelDuringASuspendedReconfigurationLeavesItToCommitAndAnswer() async throws {
        let transport = IncarnationTransport()
        let backend = IncarnationBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "warm up"])
        let teardown = await backend.pinShutdown()
        let setModel = Task {
            try await bridge.setModel(id: .number(3), params: ["sessionId": sessionID, "modelId": "other-model"])
        }
        await teardown.reached.wait()

        // The cancel answers at once, as always, and cancels nothing.
        try await bridge.cancel(id: .number(4), params: ["sessionId": sessionID])
        #expect(transport.responses(id: 4).count == 1)
        #expect(transport.responses(id: 3).isEmpty)

        teardown.release.open()
        try await setModel.value
        #expect(transport.responses(id: 3).count == 1)
        #expect(transport.responses(id: 3).first?["error"] == nil)
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "other-model")
        #expect(await bridge.testActivePromptID(sessionID: sessionID) == nil)
        try await bridge.prompt(id: .number(5), params: ["sessionId": sessionID, "prompt": "after"])
        #expect(transport.stopReason(id: 5) == "end_turn")

        await bridge.shutdown()
    }

    @Test
    func aRunningPromptRefusesReconfigurationAndAReconfigurationRefusesPrompts() async throws {
        let transport = IncarnationTransport()
        let backend = IncarnationBackend()
        let bridge = try Self.makeBridge(transport: transport, backend: backend)

        try await bridge.newSession(id: .number(1), params: Self.sessionParams())
        let sessionID = try #require(await bridge.testAnySessionID())
        let pin = await backend.pin("long turn")
        let prompt = Task {
            try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "long turn"])
        }
        await pin.started.wait()

        await #expect(throws: ACPError.self) {
            try await bridge.setModel(id: .number(3), params: ["sessionId": sessionID, "modelId": "other-model"])
        }
        await #expect(throws: ACPError.self) {
            try await bridge.setConfigOption(
                id: .number(4),
                params: ["sessionId": sessionID, "configId": "model", "value": "other-model"]
            )
        }
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "test-model")
        pin.finish.open()
        try await prompt.value
        #expect(transport.stopReason(id: 2) == "end_turn")

        // A reconfiguration suspended in the runner holds the session: a
        // prompt is refused as if one were running, and the session is
        // usable again once the reconfiguration commits.
        let teardown = await backend.pinShutdown()
        let setModel = Task {
            try await bridge.setModel(id: .number(5), params: ["sessionId": sessionID, "modelId": "other-model"])
        }
        await teardown.reached.wait()
        await #expect(throws: ACPError.self) {
            try await bridge.prompt(id: .number(6), params: ["sessionId": sessionID, "prompt": "refused"])
        }
        teardown.release.open()
        try await setModel.value
        #expect(transport.responses(id: 5).count == 1)
        #expect(await bridge.telegramTestConfiguration(sessionID: sessionID)?.modelID == "other-model")
        try await bridge.prompt(id: .number(7), params: ["sessionId": sessionID, "prompt": "accepted"])
        #expect(transport.stopReason(id: 7) == "end_turn")
        #expect(await backend.prompts.contains { $0.contains("refused") } == false)

        await bridge.shutdown()
    }
}
