//
//  DirectSubAgentRuntimeTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 02/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DirectSubAgentRuntimeTests {
    @Test
    func createAgentsUsesMatchedProfileModelFromRole() async throws {
        let planner = AgentProfile(
            id: "planner-profile",
            name: "Planner",
            tools: [],
            modelID: "planner-model",
            thinkingSelection: .high
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [planner]
                )
            }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("planning-pass"),
                "role": .string("Planner"),
                "isolationMode": .string("report")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == planner)
        #expect(context.modelID == "planner-model")
        #expect(context.thinkingSelection == .high)
        #expect(await backend.createdThinkingSelection() == .high)

        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.modelID == "planner-model")
        #expect(output.contains("model=planner-model"))
    }
}

private final class SubAgentFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedContexts: [DirectSubAgentRuntime.BackendContext] = []

    var contexts: [DirectSubAgentRuntime.BackendContext] {
        lock.lock()
        defer { lock.unlock() }
        return recordedContexts
    }

    func append(_ context: DirectSubAgentRuntime.BackendContext) {
        lock.lock()
        recordedContexts.append(context)
        lock.unlock()
    }
}

private actor CapturingSubAgentRuntimeBackend: AgentRuntimeBackend {
    private var thinkingSelection: AgentThinkingSelection?

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        self.thinkingSelection = thinkingSelection
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

    func closeSession(id _: String) {}

    func shutdown() {}

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
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(
            text: "done",
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func createdThinkingSelection() -> AgentThinkingSelection? {
        thinkingSelection
    }
}
