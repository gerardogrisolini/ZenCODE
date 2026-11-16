//
//  ACPSessionLifecycleConcurrencyTests+Interleaving.swift
//  ZenCODE
//
//  Lifecycle test of interleaved ACP sessions across a backend replacement,
//  with the backend factory and the recording runtime backend it uses.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

final class ACPMultiSessionBackendFactory: Sendable {
    struct PromptObservation: Sendable, Equatable {
        let sessionID: String
        let modelID: String?
        let workingDirectoryPath: String
        let systemPrompt: String?
        let allowedToolNames: Set<String>?
        let history: [AgentRuntimeMessage]
        let prompt: String
        let output: String
    }

    private struct State {
        var configurations: [(modelID: String?, workingDirectoryPath: String)] = []
        var observations: [PromptObservation] = []
    }

    private let state = Mutex(State())

    fileprivate func makeBackend(configuration: AgentRuntimeConfiguration) -> ACPMultiSessionRuntimeBackend {
        state.withLock {
            $0.configurations.append((configuration.modelID, configuration.workingDirectory.path))
        }
        return ACPMultiSessionRuntimeBackend(
            modelID: configuration.modelID,
            workingDirectoryPath: configuration.workingDirectory.path,
            record: { [weak self] observation in
                self?.state.withLock { $0.observations.append(observation) }
            }
        )
    }

    var observations: [PromptObservation] {
        state.withLock { $0.observations }
    }

    var configurations: [(modelID: String?, workingDirectoryPath: String)] {
        state.withLock { $0.configurations }
    }
}

extension ACPSessionLifecycleConcurrencyTests {
    @Test
    func interleavedACPSessionsKeepConfigurationHistorySnapshotsAndOutputAcrossBackendReplacement() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-multisession-\(UUID().uuidString)", isDirectory: true)
        let cwdA = root.appendingPathComponent("workspace-a", isDirectory: true)
        let cwdB = root.appendingPathComponent("workspace-b", isDirectory: true)
        let factory = ACPMultiSessionBackendFactory()
        let wire = Mutex<[JSONValue]>([])
        let writer = ACPWriter(sink: { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                wire.withLock { $0.append(value) }
            }
        })
        let configuration = try AgentConfiguration(
            hostedModelID: "model-a",
            availableModels: [
                AgentSettingsModelManifest(id: "model-a", kind: .remoteAPI, modelID: "local/model-a"),
                AgentSettingsModelManifest(id: "model-b", kind: .remoteAPI, modelID: "local/model-b"),
            ],
            runMode: .acp,
            workingDirectory: root
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: { runtimeConfiguration, _ in
                factory.makeBackend(configuration: runtimeConfiguration)
            }
        )
        let sessionA = AgentCoreSessionConfiguration(
            sessionID: "session-a",
            modelID: "model-a",
            workingDirectory: cwdA,
            systemPrompt: "system-a",
            cacheKey: "cache-a",
            history: [AgentRuntimeMessage(role: .user, content: "seed-a")],
            allowedToolNames: ["tool-a"]
        )
        let sessionB = AgentCoreSessionConfiguration(
            sessionID: "session-b",
            modelID: "model-b",
            workingDirectory: cwdB,
            systemPrompt: "system-b",
            cacheKey: "cache-b",
            history: [AgentRuntimeMessage(role: .user, content: "seed-b")],
            allowedToolNames: ["tool-b"]
        )
        await bridge.installTestSession(sessionA)
        await bridge.installTestSession(sessionB)

        // Two concurrently alive tasks model independent ACP clients. Explicit
        // gates interleave them as A -> B -> A without timing sleeps.
        let bMayPrompt = ACPLifecycleGate()
        let aMayPromptAgain = ACPLifecycleGate()
        async let clientA: Void = {
            try await bridge.prompt(id: .number(1), params: [
                "sessionId": sessionA.sessionID,
                "prompt": "a-one",
            ])
            bMayPrompt.open()
            await aMayPromptAgain.wait()
            try await bridge.prompt(id: .number(3), params: [
                "sessionId": sessionA.sessionID,
                "prompt": "a-two",
            ])
        }()
        async let clientB: Void = {
            await bMayPrompt.wait()
            try await bridge.prompt(id: .number(2), params: [
                "sessionId": sessionB.sessionID,
                "prompt": "b-one",
            ])
            aMayPromptAgain.open()
        }()
        _ = try await (clientA, clientB)

        let observations = factory.observations
        #expect(observations.map(\.sessionID) == ["session-a", "session-b", "session-a"])
        #expect(observations.map(\.modelID) == ["model-a", "model-b", "model-a"])
        #expect(observations.map(\.workingDirectoryPath) == [cwdA.path, cwdB.path, cwdA.path])
        #expect(observations[0].systemPrompt == "system-a")
        #expect(observations[1].systemPrompt == "system-b")
        #expect(observations[2].allowedToolNames == ["tool-a"])
        #expect(observations[2].history.map(\.content) == ["seed-a", "a-one", observations[0].output])
        #expect(!observations[2].history.contains { $0.content.contains("b-one") })

        let snapshotA = try #require(await bridge.sessionRunner.snapshotSession(id: sessionA.sessionID))
        let snapshotB = try #require(await bridge.sessionRunner.snapshotSession(id: sessionB.sessionID))
        #expect(snapshotA.workingDirectoryPath == cwdA.path)
        #expect(snapshotB.workingDirectoryPath == cwdB.path)
        #expect(snapshotA.history.map(\.content) == ["seed-a", "a-one", observations[0].output, "a-two", observations[2].output])
        #expect(snapshotB.history.map(\.content) == ["seed-b", "b-one", observations[1].output])
        #expect(!snapshotA.history.contains { $0.content.contains("b-one") })
        #expect(!snapshotB.history.contains { $0.content.contains("a-one") })

        let results = wire.withLock { values in
            values.compactMap { value -> (Int, String)? in
                guard let object = value.objectValue,
                      let id = object["id"]?.numberValue.map(Int.init),
                      let result = object["result"]?.objectValue,
                      let stopReason = result["stopReason"]?.stringValue else { return nil }
                return (id, stopReason)
            }
        }
        #expect(results.map(\.0) == [1, 2, 3])
        #expect(results.allSatisfy { $0.1 == "end_turn" })
        let outputUpdates = wire.withLock { values in
            values.compactMap { value -> (String, String)? in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let params = object["params"]?.objectValue,
                      let sessionID = params["sessionId"]?.stringValue,
                      let update = params["update"]?.objectValue,
                      update["sessionUpdate"] == .string("agent_message_chunk"),
                      let text = update["content"]?.objectValue?["text"]?.stringValue,
                      text.hasPrefix("output[") else { return nil }
                return (sessionID, text)
            }
        }
        #expect(outputUpdates.map(\.0) == ["session-a", "session-b", "session-a"])
        #expect(outputUpdates.map(\.1) == observations.map(\.output))
        #expect(factory.configurations.map(\.modelID) == ["model-a", "model-b", "model-a"])
        #expect(await bridge.sessionRunner.taskOrchestrator.registeredSessionIDs() == ["session-a", "session-b"])
    }
}

private actor ACPMultiSessionRuntimeBackend: AgentRuntimeBackend {
    private let modelID: String?
    private let workingDirectoryPath: String
    private let record: @Sendable (ACPMultiSessionBackendFactory.PromptObservation) -> Void
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

    init(
        modelID: String?,
        workingDirectoryPath: String,
        record: @escaping @Sendable (ACPMultiSessionBackendFactory.PromptObservation) -> Void
    ) {
        self.modelID = modelID
        self.workingDirectoryPath = workingDirectoryPath
        self.record = record
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
        id: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard let snapshot = sessions[id] else { return }
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            systemPrompt: systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: snapshot.history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        modelID ?? "default"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        guard let snapshot = sessions[sessionID] else {
            throw ACPError.invalidParams("Backend replacement lost session \(sessionID)")
        }
        let output = "output[\(sessionID)|\(modelID ?? "default")|\(URL(fileURLWithPath: workingDirectoryPath).lastPathComponent)|\(prompt)]"
        record(ACPMultiSessionBackendFactory.PromptObservation(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            allowedToolNames: snapshot.allowedToolNames,
            history: snapshot.history,
            prompt: prompt,
            output: output
        ))
        var history = snapshot.history
        history.append(AgentRuntimeMessage(role: .user, content: prompt))
        history.append(AgentRuntimeMessage(role: .assistant, content: output))
        sessions[sessionID] = AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            workingDirectoryPath: snapshot.workingDirectoryPath,
            systemPrompt: snapshot.systemPrompt,
            cacheKey: snapshot.cacheKey,
            history: history,
            allowedToolNames: snapshot.allowedToolNames,
            thinkingSelection: snapshot.thinkingSelection,
            preserveThinking: snapshot.preserveThinking
        )
        await onEvent(.content(output))
        return DirectAgentResponse(text: output, stopReason: "end_turn", modelID: modelID ?? "default")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}
