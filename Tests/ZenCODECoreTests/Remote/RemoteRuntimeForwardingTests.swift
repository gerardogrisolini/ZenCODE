import Foundation
import Synchronization
import Testing
import ZenCODECore

// Deliberately no @testable: inherited forwarding remains public on each client.
@Suite("Remote runtime forwarding")
struct RemoteRuntimeForwardingTests {
    @Test(arguments: ["remote", "anthropic", "chatgpt"])
    func sharedChatPreservesConcreteAndExistentialDispatch(provider: String) async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        let configuration = AgentRuntimeConfiguration(
            modelID: "test-model",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
        let remoteProvider = AgentRemoteProvider(
            name: "Test", baseURL: "https://unit.test/v1",
            modelID: "test-model", chatEndpoint: .responses
        )
        let backend: any AgentRuntimeBackend
        let concreteDelivery: AgentSharedChat.Delivery
        switch provider {
        case "remote":
            let client = RemoteGenerationClient(
                configuration: configuration, provider: remoteProvider, apiKey: nil,
                sharedChat: chat, sharedChatRootSessionID: "root"
            )
            concreteDelivery = try await client.sendSharedChatMessage(
                text: "concrete", destination: .coordinator, rootSessionID: "root"
            )
            backend = client
        case "anthropic":
            let client = AnthropicSubscriptionGenerationClient(
                configuration: configuration, provider: remoteProvider,
                sharedChat: chat, sharedChatRootSessionID: "root"
            )
            concreteDelivery = try await client.sendSharedChatMessage(
                text: "concrete", destination: .coordinator, rootSessionID: "root"
            )
            backend = client
        default:
            let client = ChatGPTSubscriptionGenerationClient(
                configuration: configuration,
                sharedChat: chat, sharedChatRootSessionID: "root"
            )
            concreteDelivery = try await client.sendSharedChatMessage(
                text: "concrete", destination: .coordinator, rootSessionID: "root"
            )
            backend = client
        }
        let notifications = Mutex<[String]>([])
        await backend.updateSharedChatMessageAvailableHandler { room in
            notifications.withLock { $0.append(room) }
        }
        let messageID = UUID()
        let delivery = try await backend.sendSharedChatMessage(
            text: "correlated", destination: .coordinator,
            rootSessionID: "root", messageID: messageID
        )
        let legacyDelivery = try await backend.sendSharedChatMessage(
            text: "existential", destination: .coordinator, rootSessionID: "root"
        )
        #expect(delivery.message.id == messageID)
        #expect(concreteDelivery.message.id != messageID)
        #expect(legacyDelivery.message.id != messageID)
        #expect(delivery.message.sender.kind == .operator)
        #expect(delivery.recipients.map(\.id) == [AgentSharedChat.coordinatorID(for: "root")])
        #expect(notifications.withLock { $0 } == ["root", "root"])
        let participants = await backend.sharedChatParticipants(rootSessionID: "root")
        #expect(participants.count == 2)
        #expect(participants.contains { $0.id == AgentSharedChat.coordinatorID(for: "root") })
        let expectedIDs = [concreteDelivery.message.id, messageID, legacyDelivery.message.id]
        #expect(await backend.sharedChatTranscriptMessages(rootSessionID: "root").map(\.id) == expectedIDs)
        #expect(await backend.drainCoordinatorSharedChatMessages(rootSessionID: "root").map(\.id) == expectedIDs)
        #expect(await backend.drainCoordinatorSharedChatMessages(rootSessionID: "root").isEmpty)
        #expect(await backend.sharedChatTranscriptMessages(rootSessionID: "root").map(\.id) == expectedIDs)
        await backend.updateSharedChatMessageAvailableHandler(nil)
        _ = try await backend.sendSharedChatMessage(
            text: "no callback", destination: .coordinator, rootSessionID: "root"
        )
        #expect(notifications.withLock { $0 } == ["root", "root"])
        #expect(await backend.subAgentSnapshots().isEmpty)
        #expect(await backend.closeSubAgent(id: "missing") == false)
        #expect(await backend.interruptSubAgents(rootSessionID: "root") == 0)
        #expect(await backend.interruptBackgroundJobs() == 0)
        await backend.shutdown()
    }

    @Test
    func externalBackendKeepsLegacyWitnessAndFailClosedCorrelation() async throws {
        let backend: any AgentRuntimeBackend = ExternalLegacyBackend()
        let delivery = try await backend.sendSharedChatMessage(
            text: "legacy", destination: .coordinator, rootSessionID: "root"
        )
        #expect(delivery.message.text == "legacy")
        await #expect(throws: AgentSharedChat.Error.unavailable) {
            try await backend.sendSharedChatMessage(
                text: "correlated", destination: .coordinator,
                rootSessionID: "root", messageID: UUID()
            )
        }
        #expect(await backend.sharedChatParticipants(rootSessionID: "root").isEmpty)
        #expect(await backend.interruptBackgroundJobs() == 0)
    }
}

// An external-style conformer supplies only the original backend requirements;
// it must neither acquire an executor nor opt into the internal refinement.
private actor ExternalLegacyBackend: AgentRuntimeBackend {
    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {}
    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {}
    func updateSessionOptions(
        id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {}
    func closeSession(id: String) async {}
    func shutdown() async {}
    func compactSession(id: String, force: Bool) async -> AgentRuntimeSessionCompactionResult? { nil }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { nil }
    func sendPrompt(
        sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        throw AgentSharedChat.Error.unavailable
    }
    func sendSharedChatMessage(
        text: String, destination: AgentSharedChat.Destination, rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: rootSessionID)
        _ = try await chat.registerAgent(id: "legacy", name: "Legacy", roomID: rootSessionID)
        return try await chat.send(
            roomID: rootSessionID, senderID: "legacy",
            destination: destination, text: text
        )
    }
}
