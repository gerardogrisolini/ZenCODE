//
//  ChatSessionSubAgentTranscriptTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// The live sub-agent transcript through the whole public chain:
/// `ChatSessionController` → `AgentCoreSessionRunner` → `AgentCoreBackend` →
/// a direct-tool backend → `DirectToolExecutor` → `DirectSubAgentRuntime`,
/// without a provider.
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionSubAgentTranscriptTests {
    @Test
    func theControllerReadsTheTranscriptOfItsSessionsSubAgents() async throws {
        try await withChatHarness { harness in
            let rootSessionID = harness.controller.sessionID
            let subAgentBackend = TranscriptRecordingSubAgentBackend()
            let rootBackend = TranscriptRootToolBackend(subAgentBackend: subAgentBackend)
            let runner = AgentCoreSessionRunner(backendFactory: { _, _ in rootBackend })
            let controller = Self.controller(sessionID: rootSessionID, runtime: runner, harness: harness)

            // Without a backend there is nothing to read.
            #expect(await controller.subAgentTranscript(agentID: "agent_missing") == nil)

            let configuration = AgentCoreSessionConfiguration(
                sessionID: rootSessionID,
                modelID: "test-model",
                workingDirectory: harness.workspace,
                systemPrompt: nil,
                cacheKey: nil,
                history: [],
                allowedToolNames: []
            )
            try await runner.createSession(configuration: configuration)
            _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })

            // The coordinator's `agent.create` in this session: the executor
            // registers the agent under the session ID as its root.
            let creation = await rootBackend.toolExecutor.execute(
                sessionID: rootSessionID,
                toolCall: presentedToolCall(
                    id: "create-reader",
                    name: "agent.create",
                    argumentsObject: [
                        "name": "reader",
                        "profile": "Developer",
                        "prompt": "Summarize",
                    ],
                    argumentsJSON: #"{"name":"reader","profile":"Developer","prompt":"Summarize"}"#
                ),
                workingDirectory: harness.workspace
            )
            #expect(creation.status == .completed)
            let runtime = await rootBackend.toolExecutor.subAgentRuntime
            await runtime.waitForDirectSubAgentTestWorkLoops()
            let agentID = try #require(await runtime.snapshots().first?.id)

            let live = try #require(await controller.subAgentTranscript(agentID: agentID))
            #expect(live.agentID == agentID)
            #expect(transcriptLabels(live.kinds) == oneRoundLabels(prompt: "Summarize") + [
                "text:Finished: Summarize",
            ])
            #expect(await runner.subAgentTranscript(agentID: agentID, rootSessionID: rootSessionID) == live)

            // A controller of another session does not see the agent.
            let otherController = Self.controller(sessionID: "other-session", runtime: runner, harness: harness)
            #expect(await otherController.subAgentTranscript(agentID: agentID) == nil)

            // The close shuts the agent's backend down: the Core keeps no
            // copy, so there is nothing left to read.
            #expect(await runner.closeSubAgent(id: agentID))
            #expect(await subAgentBackend.shutdownCount() == 1)
            #expect(await controller.subAgentTranscript(agentID: agentID) == nil)

            await runner.shutdown()
        }
    }

    @ChatSessionActor
    private static func controller(
        sessionID: String,
        runtime: any ChatSessionRuntime,
        harness: ChatManagementHarness
    ) -> ChatSessionController {
        ChatSessionController(
            sessionID: sessionID,
            runtime: runtime,
            environment: harness.controller.environment,
            workingDirectory: harness.workspace,
            presenter: harness.presenter,
            host: harness.host,
            authorizer: harness.controller.authorizer
        )
    }
}

/// A root backend that owns a direct-tool executor, as the production remote
/// clients do, whose delegated agents run on `subAgentBackend`. Its own
/// turns are never sent: the test drives the executor directly.
private actor TranscriptRootToolBackend: DirectToolRuntimeBackend {
    let toolExecutor: DirectToolExecutor

    init(subAgentBackend: TranscriptRecordingSubAgentBackend) {
        toolExecutor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in subAgentBackend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
    }

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {
        await toolExecutor.subAgentRuntime.shutdown()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func activeToolDescriptors(sessionID _: String?) async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "root", stopReason: "stop", modelID: "test-model")
    }
}
