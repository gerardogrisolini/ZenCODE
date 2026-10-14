import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func sharedChatIdentityIsIncludedInEveryChildBackendContext() async throws {
        let recorder = SubAgentFactoryRecorder()
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
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
        let context = try #require(recorder.contexts.first)
        #expect(context.sharedChat != nil)
        #expect(context.sharedChatSenderID == agentID)
        #expect(context.sharedChatRoomID == "root")
        await runtime.shutdown()
    }

    @Test
    func childBorrowedAgentToolsUseParentGraphAndCapturedChatIdentity() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
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

        let listOutput = try await backend.executeBorrowedSubAgentTool(
            AgentBorrowedToolCall(
                id: "list-call",
                name: "agent.list",
                argumentsJSON: "{}"
            )
        )
        #expect(listOutput.contains("worker"))

        _ = try await backend.executeBorrowedSubAgentTool(
            AgentBorrowedToolCall(
                id: "message-call",
                name: "agent.message",
                argumentsJSON: #"{"to":"coordinator","message":"Live finding"}"#
            )
        )
        let messages = await runtime.drainCoordinatorSharedChatMessages(rootSessionID: "root")
        #expect(messages.map(\.sender.name) == ["worker"])
        #expect(messages.map(\.text) == ["Live finding"])
        await runtime.shutdown()
    }

    @Test
    func childDirectToolExecutorBorrowsOnlyAgentToolsAndKeepsTaskAndTodoRuntimesLocal() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let unavailableFactory: DirectSubAgentContextualBackendFactory = { _ in
            throw DirectSubAgentBackendFactoryError.unavailable
        }
        let rootExecutor = DirectToolExecutor(
            subAgentContextualBackendFactory: unavailableFactory
        )
        await rootExecutor.installTaskOrchestrator(orchestrator)
        _ = try await rootExecutor.executeThrowing(
            sessionID: "root",
            toolCall: directToolCall(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [["id": "report", "title": "Report findings"]],
                ]
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            allowedToolNames: ["tasks.create"]
        )

        let backend = CapturingSubAgentRuntimeBackend()
        let parentRuntime = makeDirectSubAgentRuntime(backend: backend)
        await parentRuntime.installTaskOrchestrator(orchestrator)
        _ = try await parentRuntime.createAgents(
            arguments: [
                "name": .string("worker"),
                "profile": .string("Developer"),
                "taskID": .string("report"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["tasks.create"],
            rootSessionID: "root"
        )
        let child = try #require(await parentRuntime.snapshots().first)
        let childSessionID = "\(child.id)_session"
        let childExecutor = DirectToolExecutor(
            borrowedSubAgentToolExecutor: { toolCall in
                try await parentRuntime.executeBorrowedSubAgentTool(
                    senderID: child.id,
                    rootSessionID: "root",
                    toolCall: toolCall
                )
            },
            subAgentContextualBackendFactory: unavailableFactory
        )
        await childExecutor.installTaskOrchestrator(orchestrator)
        let allowedToolNames: Set<String> = [
            "agent.list", "agent.get", "agent.message",
            "tasks.list", "tasks.get", "tasks.update",
            "todo.read", "todo.write",
        ]
        let workingDirectory = URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests")

        let taskList = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "tasks.list", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let taskDetails = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "tasks.get", arguments: ["id": "report"]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let taskUpdate = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "tasks.update",
                arguments: ["id": "report", "progress": "reported from child"]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let todoWrite = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "todo.write",
                arguments: [
                    "todos": [["id": "handoff", "content": "Review the report"]],
                ]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let todoRead = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "todo.read", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )

        let agentList = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "agent.list", arguments: [:]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        let agentDetails = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(name: "agent.get", arguments: ["id": child.id]),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )
        _ = try await childExecutor.executeThrowing(
            sessionID: childSessionID,
            toolCall: directToolCall(
                name: "agent.message",
                arguments: ["to": "coordinator", "message": "Report is ready"]
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: allowedToolNames
        )

        #expect(taskList.contains("report"))
        #expect(taskDetails.contains("Report findings"))
        #expect(taskUpdate.contains("reported from child"))
        #expect(todoWrite.contains("Review the report"))
        #expect(todoRead.contains("Review the report"))
        #expect(agentList.contains("worker"))
        #expect(agentDetails.contains("worker"))
        let coordinatorMessages = await parentRuntime.drainCoordinatorSharedChatMessages(
            rootSessionID: "root"
        )
        #expect(coordinatorMessages.map(\.sender.id) == [child.id])
        #expect(coordinatorMessages.map(\.text) == ["Report is ready"])

        await childExecutor.shutdown()
        await rootExecutor.shutdown()
        await parentRuntime.shutdown()
    }
}

private func directToolCall(
    name: String,
    arguments: [String: Any]
) -> DirectAgentToolCall {
    let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
    return DirectAgentToolCall(
        id: UUID().uuidString,
        name: name,
        argumentsObject: arguments,
        argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    )
}
