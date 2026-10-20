import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    // MARK: - agent.message awaitReply

    @Test
    func awaitReplyReturnsTheReplyAndLeavesNoMailboxCopy() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let waiting = Task {
            try await fixture.backend.executeBorrowedSubAgentTool(
                awaitReplyCall(#""to":"coordinator","message":"Which API?","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForCoordinatorMailbox()
        let question = await fixture.runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        #expect(question.map(\.text) == ["Which API?"])

        _ = try await fixture.runtime.execute(
            rootSessionID: "root",
            toolCall: presentedToolCall(
                id: "reply",
                name: "agent.message",
                argumentsObject: ["id": fixture.agentID, "message": "Use the v2 API"],
                argumentsJSON: #"{"id":"\#(fixture.agentID)","message":"Use the v2 API"}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            allowedToolNames: nil
        )

        let output = try await waiting.value
        #expect(output.hasPrefix("Delivered live message to Coordinator"))
        #expect(output.contains("[Live chat reply received while you were waiting]"))
        #expect(output.components(separatedBy: "Use the v2 API").count == 2)
        #expect(output.contains("Act on this reply, then resume your assigned work."))
        // The reply was consumed by the waiting call: no second delivery.
        #expect(await fixture.runtime.sharedChat.drain(
            roomID: "root",
            participantID: fixture.agentID
        ).isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyAcceptsSnakeCaseAliasesAndTimesOutExplicitly() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let started = ContinuousClock.now
        let output = try await fixture.backend.executeBorrowedSubAgentTool(
            awaitReplyCall(#""to":"coordinator","message":"Anyone?","await_reply":"true","reply_timeout_seconds":0.1"#)
        )
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(output.hasPrefix("Delivered live message to Coordinator"))
        #expect(output.contains("No live reply arrived within 1 seconds."))
        #expect(output.contains("Do not proceed on assumptions"))
        #expect(output.contains("report it as a blocker"))
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyIsRejectedForTheCoordinatorBeforeSending() async throws {
        let fixture = try await AwaitReplyFixture.make()
        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await fixture.runtime.execute(
                rootSessionID: "root",
                toolCall: presentedToolCall(
                    id: "coordinator-await",
                    name: "agent.message",
                    argumentsObject: [
                        "id": fixture.agentID, "message": "Hello", "awaitReply": true,
                    ],
                    argumentsJSON: #"{"id":"\#(fixture.agentID)","message":"Hello","awaitReply":true}"#
                ),
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                allowedToolNames: nil
            )
        }
        #expect(await fixture.runtime.sharedChat.drain(
            roomID: "root",
            participantID: fixture.agentID
        ).isEmpty)
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyStopsWhenTheWaitingAgentIsClosed() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let waiting = Task {
            try await fixture.backend.executeBorrowedSubAgentTool(
                awaitReplyCall(#""to":"coordinator","message":"Blocked","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForCoordinatorMailbox()
        #expect(await fixture.runtime.closeAgent(id: fixture.agentID))

        let output = try await waiting.value
        #expect(output.contains(DirectSubAgentRuntime.sharedChatReplySenderStoppedText))
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyStopsWhenTheTaskAttemptIsFailedDuringTheWait() async throws {
        let fixture = try await AwaitReplyFixture.make(taskID: "task-a")
        let orchestrator = try #require(fixture.orchestrator)
        let waiting = Task {
            try await fixture.backend.executeBorrowedSubAgentTool(
                awaitReplyCall(#""to":"coordinator","message":"Blocked","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForCoordinatorMailbox()
        let attemptID = try #require(
            try await orchestrator.task(sessionID: "root", taskID: "task-a").task.activeAttemptID
        )
        _ = try await orchestrator.failAttempt(
            sessionID: "root",
            taskID: "task-a",
            attemptID: attemptID,
            error: "Validation failed"
        )

        let output = try await waiting.value
        #expect(output.contains(DirectSubAgentRuntime.sharedChatReplyAttemptInactiveText))
        #expect(!output.contains(DirectSubAgentRuntime.sharedChatReplyCancelledText))
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyStopsPromptlyOnCancellation() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let waiting = Task {
            try await fixture.backend.executeBorrowedSubAgentTool(
                awaitReplyCall(#""to":"coordinator","message":"Blocked","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForCoordinatorMailbox()
        let started = ContinuousClock.now
        waiting.cancel()

        let output = try await waiting.value
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(output.contains(DirectSubAgentRuntime.sharedChatReplyCancelledText))
        await fixture.runtime.shutdown()
    }

    // MARK: - agent.wait early return

    @Test
    func agentWaitReturnsEarlyWithoutDrainingTheCoordinatorMailbox() async throws {
        let fixture = try await AwaitReplyFixture.make()
        _ = try await fixture.backend.executeBorrowedSubAgentTool(
            awaitReplyCall(#""to":"coordinator","message":"Need a decision""#)
        )
        let started = ContinuousClock.now
        let output = await fixture.runtime.waitForAgents(
            arguments: ["timeoutSeconds": .number(30)],
            roomID: "root"
        )
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(output.hasPrefix(
            "Live chat messages are waiting for you; reply with agent.message, then call agent.wait again.\n"
        ))
        #expect(output.contains("worker"))
        // Probing is non-destructive: the inline executor delivery owns the batch.
        let pending = await fixture.runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        #expect(pending.map(\.text) == ["Need a decision"])
        await fixture.runtime.shutdown()
    }

    @Test
    func agentWaitWithoutMessagesStillWaitsForCompletionOrTimeout() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let output = await fixture.runtime.waitForAgents(
            arguments: ["timeoutSeconds": .number(1), "pollIntervalSeconds": .number(0.2)],
            roomID: "root"
        )
        #expect(output.hasPrefix("Timed out waiting for delegated sub-agents.\n"))
        await fixture.runtime.shutdown()
    }

    @Test
    func coordinatorAgentWaitDeliversWaitingMessagesInlineInTheSameResult() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests")
        let create = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "create",
                name: "agent.create",
                argumentsObject: ["name": "worker", "profile": "Developer", "prompt": "Work"],
                argumentsJSON: #"{"name":"worker","profile":"Developer","prompt":"Work"}"#
            ),
            workingDirectory: workingDirectory
        )
        #expect(create.status == .completed)
        await backend.waitUntilSentPromptCount(1)
        _ = try await backend.executeBorrowedSubAgentTool(
            awaitReplyCall(#""to":"coordinator","message":"Inline question""#)
        )

        let wait = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "wait",
                name: "agent.wait",
                argumentsObject: ["timeoutSeconds": 30],
                argumentsJSON: #"{"timeoutSeconds":30}"#
            ),
            workingDirectory: workingDirectory
        )
        #expect(wait.output.hasPrefix("Live chat messages are waiting for you"))
        #expect(wait.modelOutput.contains("[Live chat messages received while you were working]"))
        #expect(wait.modelOutput.contains("Inline question"))
        #expect(await executor.subAgentRuntime.drainCoordinatorSharedChatMessages(
            rootSessionID: "root"
        ).isEmpty)
        await executor.subAgentRuntime.shutdown()
    }

    @Test
    func agentWaitWithoutRoomKeepsTheOriginalCompletionOrTimeoutBehaviour() async throws {
        let fixture = try await AwaitReplyFixture.make()
        _ = try await fixture.backend.executeBorrowedSubAgentTool(
            awaitReplyCall(#""to":"coordinator","message":"Pending question""#)
        )
        await fixture.waitForCoordinatorMailbox()
        let output = await fixture.runtime.waitForAgents(
            arguments: ["timeoutSeconds": .number(1), "pollIntervalSeconds": .number(0.2)]
        )
        // No room: no early return, even though a message is waiting.
        #expect(output.hasPrefix("Timed out waiting for delegated sub-agents.\n"))
        #expect(!output.contains(DirectSubAgentRuntime.liveChatMessagesWaitingNotice))
        let pending = await fixture.runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        #expect(pending.map(\.text) == ["Pending question"])
        await fixture.runtime.shutdown()
    }

    // MARK: - Replies from other participants

    @Test
    func awaitReplyIsClosedByABroadcastFromTheCoordinator() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let waiting = Task {
            try await fixture.backend.executeBorrowedSubAgentTool(
                awaitReplyCall(#""to":"coordinator","message":"Which branch?","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForCoordinatorMailbox()
        _ = try await fixture.runtime.execute(
            rootSessionID: "root",
            toolCall: presentedToolCall(
                id: "broadcast",
                name: "agent.message",
                argumentsObject: ["to": "all", "message": "Everyone: use main"],
                argumentsJSON: #"{"to":"all","message":"Everyone: use main"}"#
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            allowedToolNames: nil
        )

        let output = try await waiting.value
        #expect(output.contains("[Live chat reply received while you were waiting]"))
        #expect(output.contains("Everyone: use main"))
        #expect(output.contains(
            "If this does not answer your question, call agent.message with awaitReply again."
        ))
        await fixture.runtime.shutdown()
    }

    @Test
    func awaitReplyIsClosedByAPeerMessage() async throws {
        let fixture = try await AwaitReplyFixture.make()
        _ = try await fixture.runtime.createAgents(
            arguments: [
                "name": .string("peer"),
                "profile": .string("Developer"),
                "prompt": .string("Help"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await fixture.backend.waitUntilSentPromptCount(2)
        let peerID = try #require(await fixture.runtime.snapshots().first { $0.name == "peer" }?.id)
        let waiting = Task {
            try await fixture.runtime.executeBorrowedSubAgentTool(
                senderID: fixture.agentID,
                rootSessionID: "root",
                toolCall: awaitReplyCall(#""id":"\#(peerID)","message":"Which file?","awaitReply":true,"replyTimeoutSeconds":30"#)
            )
        }
        await fixture.waitForMailbox(participantID: peerID)
        _ = try await fixture.runtime.executeBorrowedSubAgentTool(
            senderID: peerID,
            rootSessionID: "root",
            toolCall: awaitReplyCall(#""id":"\#(fixture.agentID)","message":"Edit Package.swift""#)
        )

        let output = try await waiting.value
        #expect(output.contains("[Live chat reply received while you were waiting]"))
        #expect(output.contains("Edit Package.swift"))
        #expect(output.contains("call agent.message with awaitReply again"))
        await fixture.runtime.shutdown()
    }

    // MARK: - End-to-end through the sub-agent's executor

    @Test
    func subAgentExecutorReturnsTheAwaitedReplyWithoutASecondInlineDelivery() async throws {
        let fixture = try await AwaitReplyFixture.make()
        let backend = fixture.backend
        let sharedChat = await fixture.runtime.sharedChat
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            borrowedSubAgentToolExecutor: { call in
                try await backend.executeBorrowedSubAgentTool(call)
            },
            sharedChat: sharedChat,
            sharedChatSenderID: fixture.agentID,
            sharedChatRootSessionID: "root",
            subAgentContextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        let workingDirectory = URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests")
        let waiting = Task {
            await executor.execute(
                sessionID: "worker-session",
                toolCall: presentedToolCall(
                    id: "ask",
                    name: "agent.message",
                    argumentsObject: [
                        "to": "coordinator", "message": "Which API?",
                        "awaitReply": true, "replyTimeoutSeconds": 30,
                    ],
                    argumentsJSON: #"{"to":"coordinator","message":"Which API?","awaitReply":true,"replyTimeoutSeconds":30}"#
                ),
                workingDirectory: workingDirectory
            )
        }
        await fixture.waitForCoordinatorMailbox()
        _ = try await fixture.runtime.execute(
            rootSessionID: "root",
            toolCall: presentedToolCall(
                id: "reply",
                name: "agent.message",
                argumentsObject: ["id": fixture.agentID, "message": "Use the v2 API"],
                argumentsJSON: #"{"id":"\#(fixture.agentID)","message":"Use the v2 API"}"#
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: nil
        )

        let result = await waiting.value
        #expect(result.status == .completed)
        #expect(result.modelOutput.components(separatedBy: "Use the v2 API").count == 2)
        #expect(!result.modelOutput.contains("[Live chat messages received while you were working]"))

        let next = await executor.execute(
            sessionID: "worker-session",
            toolCall: presentedToolCall(
                id: "list",
                name: "agent.list",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: workingDirectory
        )
        #expect(!next.modelOutput.contains("Use the v2 API"))
        await fixture.runtime.shutdown()
    }
}

private func awaitReplyCall(_ body: String) -> AgentBorrowedToolCall {
    AgentBorrowedToolCall(
        id: UUID().uuidString,
        name: "agent.message",
        argumentsJSON: "{\(body)}"
    )
}

/// One running delegated agent whose turn stays blocked, so its status is
/// `.running` exactly as during a real tool call.
private struct AwaitReplyFixture {
    let backend: CapturingSubAgentRuntimeBackend
    let runtime: DirectSubAgentRuntime
    let agentID: String
    var orchestrator: SessionTaskOrchestrator?

    /// Pass `taskID` to bind the agent to an active single-task workflow graph.
    static func make(taskID: String? = nil) async throws -> AwaitReplyFixture {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        var orchestrator: SessionTaskOrchestrator?
        var arguments: [String: JSONValue] = [
            "name": .string("worker"),
            "profile": .string("Developer"),
            "prompt": .string("Work"),
        ]
        if let taskID {
            let graphs = SessionTaskOrchestrator()
            _ = try await graphs.createGraph(
                sessionID: "root",
                id: "workflow",
                source: .workflow,
                state: .active,
                tasks: [
                    TaskDefinition(
                        id: taskID,
                        title: "Implement",
                        execution: TaskExecutionSpec(executor: .subAgent)
                    )
                ]
            )
            await runtime.installTaskOrchestrator(graphs)
            arguments["taskID"] = .string(taskID)
            orchestrator = graphs
        }
        _ = try await runtime.createAgents(
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await backend.waitUntilSentPromptCount(1)
        let agentID = try #require(await runtime.snapshots().first?.id)
        return AwaitReplyFixture(
            backend: backend,
            runtime: runtime,
            agentID: agentID,
            orchestrator: orchestrator
        )
    }

    func waitForCoordinatorMailbox(
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        await waitForMailbox(
            participantID: AgentSharedChat.coordinatorID(for: "root"),
            sourceLocation: sourceLocation
        )
    }

    /// Polls a mailbox with a hard deadline so a regression fails the test
    /// instead of hanging the suite.
    func waitForMailbox(
        participantID: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await runtime.sharedChat.hasPendingMessages(
            roomID: "root",
            participantID: participantID
        )) {
            guard ContinuousClock.now < deadline else {
                Issue.record("Timed out waiting for the mailbox of \(participantID)", sourceLocation: sourceLocation)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
