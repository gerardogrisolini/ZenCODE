//
//  SharedChatNamespaceAndBoundsTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore
import ToolCore

/// Closes review findings 2 (room-ID one-to-one), 4 (mailbox→pending
/// bounded + single-flight), 5 (direct dispatch qualified identity) and
/// 6 (enum forward-compatible Codable).
@Suite
struct SharedChatNamespaceAndBoundsTests {

    // MARK: - Finding 2: Room ID is collision-free and one-to-one

    @Test
    func roomIDsWithDistinctInternalWhitespaceDoNotCollide() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "session one")
        _ = try await chat.registerAgent(id: "agent-1", name: "alpha", roomID: "session one")

        // "session one" (single space) and "session  one" (double space) must
        // be distinct rooms. The previous promptSafeInlineText-based
        // normalization collapsed internal whitespace and collided them.
        _ = try await chat.registerCoordinator(roomID: "session  one")
        _ = try await chat.registerAgent(id: "agent-2", name: "beta", roomID: "session  one")

        let roomOne = await chat.participants(roomID: "session one")
        let roomTwo = await chat.participants(roomID: "session  one")

        #expect(roomOne.contains { $0.id == "agent-1" })
        #expect(roomTwo.contains { $0.id == "agent-2" })
        #expect(!roomOne.contains { $0.id == "agent-2" })
        #expect(!roomTwo.contains { $0.id == "agent-1" })

        // A message in one room never leaks to the other.
        _ = try await chat.send(
            roomID: "session one",
            senderID: "agent-1",
            destination: .direct(["coordinator:session one"]),
            text: "stay in my room"
        )
        let roomTwoMessages = await chat.messages(roomID: "session  one")
        #expect(!roomTwoMessages.contains { $0.text == "stay in my room" })
    }

    @Test
    func boundedRoomIdentifierRemovesControlCharsButPreservesInternalWhitespace() {
        // Control characters (tab, NUL, ESC, bidi overrides) are stripped for
        // terminal safety, but internal spaces are preserved so two room IDs
        // cannot collide.
        #expect(
            AgentSharedChat.boundedRoomIdentifier("room\tabc") == "roomabc"
        )
        #expect(
            AgentSharedChat.boundedRoomIdentifier("room\u{0}abc") == "roomabc"
        )
        #expect(
            AgentSharedChat.boundedRoomIdentifier("room abc") == "room abc"
        )
        #expect(
            AgentSharedChat.boundedRoomIdentifier("room  abc") == "room  abc"
        )
        // Leading/trailing whitespace is trimmed; a blank result is "default".
        #expect(
            AgentSharedChat.boundedRoomIdentifier("  room  ") == "room"
        )
        #expect(
            AgentSharedChat.boundedRoomIdentifier("   ") == "default"
        )
        #expect(
            AgentSharedChat.boundedRoomIdentifier("") == "default"
        )
    }

    @Test
    func coordinatorAndBusUseIdenticalRoomNormalization() async throws {
        // The coordinator and the bus must key the same room. Verify they agree
        // on a room ID that contains internal whitespace and a bidi override.
        let rawRoom = "my\u{202E} session"
        let normalized = AgentSharedChat.boundedRoomIdentifier(rawRoom)
        #expect(normalized == "my session")

        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: rawRoom)
        _ = try await chat.registerAgent(id: "agent-x", name: "x", roomID: rawRoom)

        let coordinator = AgentSharedChatCoordinator(
            source: AgentSharedChatCoordinator.Source(
                drainCoordinatorMessages: { _ in [] },
                participants: { _ in [] }
            ),
            pollInterval: .seconds(60)
        )
        // observeSubscription creates the room under the coordinator's
        // normalized key. isTrackingRoom confirms the coordinator and the bus
        // resolve the same room identity.
        _ = await coordinator.observeSubscription(roomID: rawRoom)
        #expect(await coordinator.isTrackingRoom(roomID: rawRoom))
        // The raw value with the bidi char is never a direct key, but the
        // coordinator's normalizedRoomID maps it to the same key the bus uses.
        #expect(await coordinator.isTrackingRoom(roomID: normalized))

        // The bus also sees participants under the same normalized key.
        let participants = await chat.participants(roomID: rawRoom)
        #expect(participants.contains { $0.id == "agent-x" })
        let sameParticipants = await chat.participants(roomID: normalized)
        #expect(sameParticipants.map(\.id).sorted() == participants.map(\.id).sorted())

        await coordinator.stopAll()
    }

    // MARK: - Finding 4: Mailbox drain bounded + single-flight

    @Test
    func mailboxBoundedAndDrainReturnsLimitedBatch() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "flood-room")
        _ = try await chat.registerAgent(id: "flood-agent", name: "flood", roomID: "flood-room")

        // Fill the mailbox with more messages than one drain can return.
        let messageCount = AgentSharedChat.maximumMailboxMessages + 5
        for i in 0..<messageCount {
            _ = try await chat.send(
                roomID: "flood-room",
                senderID: "flood-agent",
                destination: .coordinator,
                text: "msg \(i)"
            )
        }

        // Each drain returns at most maximumMessagesPerInjectedPrompt.
        let firstDrain = await chat.drain(
            roomID: "flood-room",
            participantID: AgentSharedChat.coordinatorID(for: "flood-room"),
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(firstDrain.count == AgentSharedChat.maximumMessagesPerInjectedPrompt)

        // Draining again returns the next bounded batch.
        let secondDrain = await chat.drain(
            roomID: "flood-room",
            participantID: AgentSharedChat.coordinatorID(for: "flood-room"),
            limit: AgentSharedChat.maximumMessagesPerInjectedPrompt
        )
        #expect(!secondDrain.isEmpty)
        #expect(secondDrain.count <= AgentSharedChat.maximumMessagesPerInjectedPrompt)

        // The retained transcript is bounded.
        let allMessages = await chat.messages(roomID: "flood-room")
        #expect(allMessages.count <= AgentSharedChat.maximumRetainedMessagesPerRoom)
    }

    @Test
    func pendingSharedChatPromptsBoundMatchesTwiceMailboxCapacity() {
        // The backpressure bound is intentionally tied to the mailbox capacity
        // so a fast producer cannot grow the pending-prompt queue without limit.
        #expect(
            DirectSubAgentRuntime.maximumPendingSharedChatPromptsPerAgent
                == AgentSharedChat.maximumMailboxMessages * 2
        )
    }

    @Test
    func agentFloodDoesNotGrowPendingPromptsWithoutLimit() async throws {
        let backend = SharedChatBoundsTestBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("flood-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-flood-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "flood-root"
        )
        // Block the backend so the agent never finishes a prompt; every
        // drained mailbox batch accumulates in pendingPrompts.
        await backend.setBlocking(true)
        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "flood-worker" }?.id
        )

        // Send more messages than the pending-prompt bound. The mailbox is
        // bounded to maximumMailboxMessages, but the drain loop must also
        // stop when pendingPrompts reaches the bound.
        let oversend = DirectSubAgentRuntime.maximumPendingSharedChatPromptsPerAgent
            * AgentSharedChat.maximumMessagesPerInjectedPrompt
            + 10
        for i in 0..<oversend {
            _ = try await runtime.sendSharedChatMessage(
                text: "flood \(i)",
                destination: .direct([agentID]),
                rootSessionID: "flood-root"
            )
        }

        // Allow drain callbacks to process.
        try await Task.sleep(for: .milliseconds(200))

        let snapshot = try #require(
            await runtime.snapshots().first { $0.name == "flood-worker" }
        )
        // The pending-prompt queue is bounded.
        #expect(snapshot.pending == true)

        await backend.setBlocking(false)
        await runtime.shutdown()
    }

    // MARK: - Finding 5: Direct dispatch uses bus bound + qualified identity

    @Test
    func coordinatorDirectMessageAppliesBusBoundAndReturnsQualifiedIdentity() async throws {
        let backend = SharedChatBoundsTestBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-direct-dispatch"),
            parentAllowedToolNames: nil,
            rootSessionID: "direct-root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "worker" }?.id
        )

        // An oversized message must be bounded the same way the live bus route
        // bounds it, and the result must include the recipient's qualified
        // identity rather than only an agent count.
        let hugeMessage = String(
            repeating: "x",
            count: AgentSharedChat.maximumMessageLength + 500
        )
        let result = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string(hugeMessage)
            ],
            rootSessionID: "direct-root",
            parentAllowedToolNames: nil
        )

        // The output includes the qualified identity (Agent (id: ..., name: ...))
        // not just "Queued message for N agents".
        #expect(result.contains("Delivered live message to"))
        #expect(result.contains("Agent (id:"))
        #expect(result.contains("name: worker"))

        await runtime.shutdown()
    }

    @Test
    func coordinatorDirectMessageRecordsInTransientTranscript() async throws {
        let backend = SharedChatBoundsTestBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend },
            profileResolver: { _ in
                AgentProfile(id: "dev", name: "Developer", tools: [])
            }
        )
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("transcript-worker"),
                "profile": .string("Developer"),
                "prompt": .string("Initial")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-transcript"),
            parentAllowedToolNames: nil,
            rootSessionID: "transcript-root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let agentID = try #require(
            await runtime.snapshots().first { $0.name == "transcript-worker" }?.id
        )

        _ = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(agentID),
                "message": .string("record me in the transcript")
            ],
            rootSessionID: "transcript-root",
            parentAllowedToolNames: nil
        )

        // The message was recorded in the transient bus transcript.
        let chat = await runtime.sharedChat
        let messages = await chat.messages(roomID: "transcript-root")
        #expect(messages.contains { $0.text == "record me in the transcript" })

        await runtime.shutdown()
    }

    // MARK: - Finding 6: ParticipantKind forward-compatible Codable

    @Test
    func participantKindDecodesUnknownRawValueToAgent() throws {
        let json = #""supervisor""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            AgentSharedChat.ParticipantKind.self,
            from: json
        )
        #expect(decoded == .agent)
    }

    @Test
    func participantKindRoundTripsKnownValues() throws {
        for kind in [
            AgentSharedChat.ParticipantKind.operator,
            .coordinator,
            .agent,
        ] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(
                AgentSharedChat.ParticipantKind.self,
                from: data
            )
            #expect(decoded == kind)
        }
    }

    @Test
    func participantKindEncodingMatchesRawValueString() throws {
        // The wire format is the plain String raw value (single-value
        // container), unchanged from the compiler-synthesized Codable.
        let data = try JSONEncoder().encode(
            AgentSharedChat.ParticipantKind.coordinator
        )
        #expect(String(data: data, encoding: .utf8) == #""coordinator""#)

        let operatorData = try JSONEncoder().encode(
            AgentSharedChat.ParticipantKind.operator
        )
        #expect(String(data: operatorData, encoding: .utf8) == #""operator""#)
    }
}

// MARK: - Minimal mock backend

/// Minimal backend that records prompts and optionally blocks to simulate a
/// slow agent. Used only within this test file.
private actor SharedChatBoundsTestBackend: AgentRuntimeBackend {
    private var prompts: [String] = []
    private var isBlocking = false

    func setBlocking(_ value: Bool) {
        isBlocking = value
    }

    func promptCount() -> Int { prompts.count }

    // AgentRuntimeBackend conformance

    func createSession(
        id: String, cwd: String, systemPrompt: String?,
        history: [AgentRuntimeMessage], cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {}

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?,
        history: [AgentRuntimeMessage], cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt,
            history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id: String, systemPrompt: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {}

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) async {}

    func closeSubAgent(id: String) async -> Bool { false }
    func interruptSubAgents(rootSessionID: String) async -> Int { 0 }

    func updateBorrowedSubAgentToolExecutor(_ executor: AgentBorrowedToolExecutor?) async {}
    func updateToolProviders(_ providers: [AgentToolProvider], sessionID: String?) async {}
    func closeSession(id: String) async {}
    func shutdown() async {}

    func compactSession(id: String, force: Bool) async -> AgentRuntimeSessionCompactionResult? {
        nil
    }

    func preloadModel(
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] { [] }

    func sharedChatParticipants(rootSessionID: String) async -> [AgentSharedChat.Participant] { [] }

    func sendSharedChatMessage(
        text: String,
        destination: AgentSharedChat.Destination,
        rootSessionID: String
    ) async throws -> AgentSharedChat.Delivery {
        throw DirectSubAgentBackendFactoryError.unavailable
    }

    func drainCoordinatorSharedChatMessages(
        rootSessionID: String
    ) async -> [AgentSharedChat.Message] { [] }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        if isBlocking {
            try await Task.sleep(for: .seconds(60))
        }
        return DirectAgentResponse(
            text: "done",
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { nil }
}
