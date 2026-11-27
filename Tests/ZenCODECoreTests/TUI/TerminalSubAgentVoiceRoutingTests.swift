import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@ChatSessionActor
@Suite("Terminal sub-agent voice routing", .timeLimit(.minutes(1)))
struct TerminalSubAgentVoiceRoutingTests {
    @Test
    func liveEventsFollowSelectionAndDiscardOldGenerations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chat = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: directory
            ), stdinIsTerminal: false, sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil),
            telegramTransportFactory: nil
        )
        let voice = SessionFakeVoiceController()
        let queue = TerminalChatEventQueue()
        chat.voiceController = voice
        chat.voiceEventQueue = queue
        let tool = presentedToolCall(id: "call", name: "local.read", argumentsObject: [:], argumentsJSON: "{}")
        func event(_ id: String, _ text: String?, lifecycle: DirectSubAgentToolEvent.Lifecycle = .started) -> DirectSubAgentToolEvent {
            DirectSubAgentToolEvent(agentID: id, agentName: id, toolCall: tool, lifecycle: lifecycle, commentary: text)
        }

        chat.offerVoiceCommentary("root stale")
        await chat.setVoiceCommentaryAgent("a")
        await chat.chatSessionPresenter.presentSubAgentToolEvent(event("b", "wrong agent"))
        await chat.chatSessionPresenter.presentSubAgentToolEvent(event("a", nil))
        await chat.chatSessionPresenter.presentSubAgentToolEvent(event("a", "completed", lifecycle: .completed(.init(output: "ok", summary: "ok"))))
        chat.offerVoiceCommentary("root suppressed")
        await chat.chatSessionPresenter.presentSubAgentToolEvent(event("a", "old detail"))
        await chat.setVoiceCommentaryAgent(nil)
        await chat.setVoiceCommentaryAgent("a")
        await chat.chatSessionPresenter.presentSubAgentToolEvent(event("a", "live detail"))
        queue.finish()
        for await queued in queue.events {
            if case let .voiceCommentary(text, agentID, generation) = queued {
                await chat.deliverVoiceCommentary(text, agentID: agentID, generation: generation, isGenerating: false)
            }
        }
        #expect(await voice.spoken.map(\.text) == ["live detail"])
        await chat.voiceTurnDidEnd(finalAnswer: "root final suppressed")
        #expect(await voice.spoken.map(\.text) == ["live detail"])
        await chat.setVoiceCommentaryAgent("b")
        await chat.deliverVoiceCommentary("old a", agentID: "a", generation: chat.voiceCommentaryGeneration, isGenerating: true)
        #expect(await voice.spoken.map(\.text) == ["live detail"])
        await chat.setVoiceCommentaryAgent(nil)
        await chat.voiceTurnDidEnd(finalAnswer: "root final")
        #expect(await voice.spoken.map(\.text) == ["live detail", "root final"])
        #expect(await voice.interruptCount == 5)
    }
}
