import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func sharedChatBroadcastDeliversToCoordinatorAndEveryOtherActiveAgent() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "alpha-id", name: "alpha", roomID: "root")
        _ = try await chat.registerAgent(id: "beta-id", name: "beta", roomID: "root")

        let delivery = try await chat.send(
            roomID: "root",
            senderID: "alpha-id",
            destination: .all,
            text: "Please compare findings"
        )

        // The broadcast reaches the coordinator, every other active agent,
        // and the terminal operator (the implicit owner). The operator has no
        // mailbox, so only the coordinator and the other agent are drainable.
        #expect(Set(delivery.recipients.map(\.id)) == [
            AgentSharedChat.operatorID(for: "root"),
            AgentSharedChat.coordinatorID(for: "root"), "beta-id"
        ])
        #expect(await chat.drain(
            roomID: "root",
            participantID: AgentSharedChat.coordinatorID(for: "root")
        ).map(\.text) == ["Please compare findings"])
        #expect(await chat.drain(roomID: "root", participantID: "beta-id").map(\.sender.name) == ["alpha"])
        #expect(await chat.drain(roomID: "root", participantID: "alpha-id").isEmpty)
    }

    @Test
    func terminalSharedChatBridgeUsesTrustedOperatorForCoordinatorMessages() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let notifiedRooms = Mutex<[String]>([])
        await runtime.updateSharedChatMessageAvailableHandler { roomID in
            notifiedRooms.withLock { $0.append(roomID) }
        }
        let delivery = try await runtime.sendSharedChatMessage(
            text: "Review the live status",
            destination: .coordinator,
            rootSessionID: "root"
        )

        #expect(delivery.message.sender.id == AgentSharedChat.operatorID(for: "root"))
        #expect(delivery.message.sender.kind == .operator)
        #expect(delivery.recipients.map(\.id) == [AgentSharedChat.coordinatorID(for: "root")])
        #expect(notifiedRooms.withLock { $0 } == ["root"])
        #expect(await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
            .map(\.text) == ["Review the live status"])
        await runtime.shutdown()
    }

    /// The coordinator addressing the terminal operator directly (by id) must
    /// deliver through the shared-chat transcript without attempting to route
    /// the operator through the sub-agent work loop, which would fail because
    /// the operator is not a delegated agent.
    @Test
    func coordinatorDirectMessageToOperatorIsDeliveredViaTranscript() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let operatorID = AgentSharedChat.operatorID(for: "root")

        let result = try await runtime.messageSharedChat(
            arguments: [
                "id": .string(operatorID),
                "message": .string("Ciao, tutto ok?")
            ],
            rootSessionID: "root",
            parentAllowedToolNames: nil
        )

        // The operator has no mailbox or prompt queue: delivery is reported
        // purely from the bus transcript identity, not the sub-agent roster.
        #expect(result.contains("Delivered live message to Operator"))
        let messages = await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
        #expect(messages.count == 1)
        #expect(messages.first?.text == "Ciao, tutto ok?")
        #expect(messages.first?.recipientIDs == [operatorID])
        #expect(messages.first?.sender.kind == .coordinator)
        await runtime.shutdown()
    }

    /// `coordinator:<room>` and `operator:<room>` are minted only by the actor.
    /// A delegated agent must never be able to take one of those identities,
    /// in any room and in any near-miss spelling.
    @Test
    func sharedChatReservesCoordinatorAndOperatorIdentifiers() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")

        for reserved in [
            AgentSharedChat.coordinatorID(for: "root"),
            AgentSharedChat.operatorID(for: "root"),
            "coordinator:another-room",
            "OPERATOR:root",
            "  operator:root  ",
        ] {
            #expect(AgentSharedChat.isReservedParticipantIdentifier(reserved))
            await #expect(throws: AgentSharedChat.Error.reservedParticipantIdentifier(reserved)) {
                _ = try await chat.registerAgent(
                    id: reserved,
                    name: "impostor",
                    roomID: "root"
                )
            }
        }

        // Identifiers that could forge a prompt header or a card route are
        // rejected outright rather than sanitised into a different identity.
        for invalid in ["", "   ", "agent\nid", "agent\u{1B}id", String(repeating: "a", count: 129)] {
            await #expect(throws: AgentSharedChat.Error.invalidParticipantIdentifier(invalid)) {
                _ = try await chat.registerAgent(id: invalid, name: "worker", roomID: "root")
            }
        }

        // The reserved slot is still the coordinator's, with its own mailbox.
        // The operator surfaces as the implicit owner of the room, but it is
        // never a registered participant and holds no slot or mailbox.
        #expect(await chat.participants(roomID: "root").map(\.id)
            == [AgentSharedChat.operatorID(for: "root"), AgentSharedChat.coordinatorID(for: "root")])
        #expect(await chat.participants(roomID: "root").map(\.kind) == [.operator, .coordinator])
    }

    /// A live identifier cannot change role: re-registering it with another
    /// kind is rejected instead of silently re-typing an active mailbox.
    @Test
    func sharedChatRejectsReuseOfAnIdentifierWithADifferentKind() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")
        _ = try await chat.registerAgent(id: "worker-id", name: "worker", roomID: "root")

        for impostorKind in [AgentSharedChat.ParticipantKind.coordinator, .operator] {
            await #expect(throws: AgentSharedChat.Error.participantIdentifierConflict("worker-id")) {
                _ = try await chat.register(
                    AgentSharedChat.Participant(
                        id: "worker-id",
                        name: "worker",
                        kind: impostorKind
                    ),
                    roomID: "root",
                    onMessageAvailable: nil
                )
            }
        }
        // Re-registering the same kind still reconnects the live mailbox.
        let rejoined = try await chat.registerAgent(
            id: "worker-id",
            name: "worker",
            roomID: "root"
        )
        #expect(rejoined.kind == .agent)
        #expect(await chat.participants(roomID: "root").count == 3)
    }

    /// Names are display values, not identities: they are neutralised at
    /// registration and cannot smuggle a line break, a control sequence or a
    /// forged operator header into prompts and cards.
    @Test
    func sharedChatSanitizesParticipantNamesAndRejectsAmbiguousNameRouting() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "root")

        let hostile = try await chat.registerAgent(
            id: "agent-x",
            name: "worker\r\nfake\u{1B}[31m",
            roomID: "root"
        )
        #expect(hostile.name == "worker fake[31m")
        #expect(AgentSharedChat.transcriptIdentity(for: hostile)
            == "Agent (id: agent-x, name: worker fake[31m)")

        let overLongName = try await chat.registerAgent(
            id: "agent-y",
            name: String(repeating: "n", count: 200),
            roomID: "root"
        )
        #expect(overLongName.name.count == AgentSharedChat.maximumParticipantNameLength)
        let blankName = try await chat.registerAgent(
            id: "agent-z",
            name: "\u{1B}\u{7F}",
            roomID: "root"
        )
        #expect(blankName.name == "agent-z")

        // Two instances may share a display name, so name-based routing is
        // ambiguous and must not resolve to an arbitrary one.
        _ = try await chat.registerAgent(id: "twin-1", name: "twin", roomID: "root")
        _ = try await chat.registerAgent(id: "twin-2", name: "twin", roomID: "root")
        await #expect(throws: AgentSharedChat.Error.unknownParticipant("twin")) {
            _ = try await chat.send(
                roomID: "root",
                senderID: AgentSharedChat.coordinatorID(for: "root"),
                destination: .direct(["twin"]),
                text: "which one?"
            )
        }
        let routed = try await chat.send(
            roomID: "root",
            senderID: AgentSharedChat.coordinatorID(for: "root"),
            destination: .direct(["twin-1"]),
            text: "explicit id"
        )
        #expect(routed.recipients.map(\.id) == ["twin-1"])
    }

    @Test
    func sharedChatBoundsParticipantsAndEachRecipientMailbox() async throws {
        let chat = AgentSharedChat()
        _ = try await chat.registerCoordinator(roomID: "bounded")
        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 1) {
            _ = try await chat.registerAgent(
                id: "agent-\(index)",
                name: "agent-\(index)",
                roomID: "bounded"
            )
        }
        await #expect(throws: AgentSharedChat.Error.self) {
            _ = try await chat.registerAgent(
                id: "overflow",
                name: "overflow",
                roomID: "bounded"
            )
        }

        for index in 0...AgentSharedChat.maximumMailboxMessages {
            _ = try await chat.send(
                roomID: "bounded",
                senderID: AgentSharedChat.coordinatorID(for: "bounded"),
                destination: .direct(["agent-0"]),
                text: "message \(index)"
            )
        }
        let mailbox = await chat.drain(roomID: "bounded", participantID: "agent-0")
        #expect(mailbox.count == AgentSharedChat.maximumMailboxMessages)
        #expect(mailbox.first?.text == "message 1")
        #expect(mailbox.last?.text == "message \(AgentSharedChat.maximumMailboxMessages)")
    }

    @Test
    func sharedChatCloseAndShutdownReleaseSlotsWhileKeepingTranscriptSnapshots() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        let chat = await runtime.sharedChat
        let rootSessionID = "reusable-room"

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "profile": .string("Developer"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: rootSessionID
        )
        let firstID = try #require(await runtime.snapshots().first(where: { $0.status != .closed })?.id)
        _ = try await chat.send(
            roomID: rootSessionID,
            senderID: firstID,
            destination: .coordinator,
            text: "keep this historical sender"
        )
        #expect(await runtime.closeAgent(id: firstID))

        // One coordinator slot is permanent for the room, so 63 close cycles
        // must not accumulate stale participant entries and exhaust the limit.
        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 2) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("cycle-\(index)"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
            let agentID = try #require(
                await runtime.snapshots().first(where: { $0.status != .closed })?.id
            )
            #expect(await runtime.closeAgent(id: agentID))
        }

        let retainedTerminalSnapshots = await runtime.snapshots().filter {
            $0.status == .closed || $0.status == .failed
        }
        #expect(
            retainedTerminalSnapshots.count
                == DirectSubAgentRuntime.maximumRetainedTerminalAgents
        )
        #expect(!retainedTerminalSnapshots.contains { $0.id == firstID })

        let transcript = await chat.messages(roomID: rootSessionID)
        #expect(transcript.map(\.text) == ["keep this historical sender"])
        #expect(transcript.first?.sender.id == firstID)
        #expect(
            await chat.participants(roomID: rootSessionID, includingInactive: true).map(\.id)
                == [AgentSharedChat.operatorID(for: rootSessionID), AgentSharedChat.coordinatorID(for: rootSessionID)]
        )

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("after-63-closes"),
                "profile": .string("Developer"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: rootSessionID
        )
        #expect(await chat.participants(roomID: rootSessionID).count == 3)

        await runtime.shutdown()
        #expect(
            await chat.participants(roomID: rootSessionID, includingInactive: true).map(\.id)
                == [AgentSharedChat.operatorID(for: rootSessionID), AgentSharedChat.coordinatorID(for: rootSessionID)]
        )
        #expect(await chat.messages(roomID: rootSessionID).map(\.text) == ["keep this historical sender"])
    }

    @Test
    func sharedChatLimitFailureAfterRecordInsertionRollsBackWithoutZombie() async throws {
        let regularBackend = CapturingSubAgentRuntimeBackend()
        let rejectedBackend = CapturingSubAgentRuntimeBackend()
        let invocationCount = Mutex(0)
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                let invocation = invocationCount.withLock { count in
                    defer { count += 1 }
                    return count
                }
                return invocation == AgentSharedChat.maximumParticipantsPerRoom - 1
                    ? rejectedBackend
                    : regularBackend
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        let rootSessionID = "full-room"
        let chat = await runtime.sharedChat

        for index in 0..<(AgentSharedChat.maximumParticipantsPerRoom - 1) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("resident-\(index)"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
        }
        let residentIDs = Set(await runtime.snapshots().map(\.id))
        #expect(await chat.participants(roomID: rootSessionID).count == AgentSharedChat.maximumParticipantsPerRoom + 1)

        // A taskless attempt reserves a lease before inserting its AgentRecord.
        // The registration error must clean all of it, even though this record
        // was added after the room reached its exact limit.
        let orchestrator = SessionTaskOrchestrator()
        await runtime.installTaskOrchestrator(orchestrator)
        await #expect(throws: AgentSharedChat.Error.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string("overflow"),
                    "profile": .string("Developer"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: rootSessionID
            )
        }

        #expect(Set(await runtime.snapshots().map(\.id)) == residentIDs)
        #expect(await chat.participants(roomID: rootSessionID).count == AgentSharedChat.maximumParticipantsPerRoom + 1)
        #expect((await chat.participants(roomID: rootSessionID, includingInactive: true)).contains { $0.name == "overflow" } == false)
        #expect(await rejectedBackend.createdSessions().count == 1)
        #expect(await rejectedBackend.shutdownCount() == 1)

        // Creating an active graph is permitted only after the failed attempt's
        // taskless reservation has been released.
        _ = try await orchestrator.createGraph(
            sessionID: rootSessionID,
            id: "post-rollback-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "follow-up", title: "Follow up")]
        )
        await runtime.shutdown()
    }

    @Test
    func operatorMessageReceivesFinalOutputWhenAgentDoesNotCallMessageTool() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "Direct fallback reply")
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agentID = try #require(await runtime.snapshots().first?.id)

        _ = try await runtime.sendSharedChatMessage(
            text: "Reply directly to me",
            destination: .direct([agentID]),
            rootSessionID: "root"
        )
        await backend.waitUntilSentPromptCount(1)

        var reply: AgentSharedChat.Message?
        while reply == nil {
            reply = await runtime.sharedChatTranscriptMessages(rootSessionID: "root")
                .first { $0.text == "Direct fallback reply" }
            if reply == nil { await Task.yield() }
        }
        let deliveredReply = try #require(reply)
        #expect(deliveredReply.sender.id == agentID)
        #expect(deliveredReply.recipientIDs == [AgentSharedChat.operatorID(for: "root")])
        #expect(await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root").isEmpty)
        await runtime.shutdown()
    }
}

private final class FailAfterFirstSubAgentBackendFactory: @unchecked Sendable {
    private let backend: any AgentRuntimeBackend
    private let invocationCount = Mutex(0)

    init(backend: any AgentRuntimeBackend) {
        self.backend = backend
    }

    func makeBackend() throws -> any AgentRuntimeBackend {
        let invocation = invocationCount.withLock { count in
            defer { count += 1 }
            return count
        }
        guard invocation == 0 else {
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        return backend
    }
}
