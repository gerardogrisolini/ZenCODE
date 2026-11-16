import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectTaskToolAdapterTests {
    @Test
    func taskBoundSessionReceivesScopedTaskUpdateDescriptionOnly() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: receipt.taskID,
                attemptID: receipt.attemptID
            )
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let rootDescriptor = try #require(await executor.descriptors(
            allowedToolNames: ["tasks.update"],
            sessionID: "root"
        ).first)
        let childDescriptor = try #require(await executor.descriptors(
            allowedToolNames: ["tasks.update"],
            sessionID: "child"
        ).first)

        #expect(rootDescriptor.description.contains("Updates task metadata"))
        #expect(!rootDescriptor.description.contains("As a task-bound sub-agent"))
        #expect(childDescriptor.description.contains("As a task-bound sub-agent"))
        #expect(childDescriptor.description.contains("final response is recorded automatically"))
        #expect(childDescriptor.inputSchema != rootDescriptor.inputSchema)
        #expect(childDescriptor.inputSchema.contains("\"progress\""))
        #expect(childDescriptor.inputSchema.contains("\"output\""))
        #expect(!childDescriptor.inputSchema.contains("\"dependsOn\""))
        #expect(!childDescriptor.inputSchema.contains("\"evidence\""))
        #expect(!childDescriptor.inputSchema.contains("\"status\""))
        #expect(!childDescriptor.inputSchema.contains("\"workflow\""))
        #expect(rootDescriptor.inputSchema.contains("\"workflow\""))
    }

    @Test
    func taskUpdatePayloadSchemasFollowTheSessionForBothOpenAIWireFormats() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: receipt.taskID,
                attemptID: receipt.attemptID
            )
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let rootProperties = try await executor.taskUpdatePayloadPropertiesForTesting(
            sessionID: "root"
        )
        let childProperties = try await executor.taskUpdatePayloadPropertiesForTesting(
            sessionID: "child"
        )

        let rootExpected = ["dependsOn", "evidence", "status", "workflow"]
        let childExpected = ["output", "progress", "statusReason", "expectedRevision"]
        for properties in [
            rootProperties.responses,
            rootProperties.chatCompletions,
        ] {
            for name in rootExpected {
                #expect(properties.contains(name))
            }
        }
        for properties in [
            childProperties.responses,
            childProperties.chatCompletions,
        ] {
            for name in childExpected {
                #expect(properties.contains(name))
            }
            for name in rootExpected {
                #expect(!properties.contains(name))
            }
        }
    }

    @Test
    func tasksNamespaceIsCanonicalAndSingularNamespaceIsRejected() {
        let advertisedNames = DirectToolCatalog.todoTaskDescriptors
            .map(\.name)
            .filter { $0.hasPrefix("tasks.") || $0.hasPrefix("task.") }
        #expect(advertisedNames == [
            "tasks.create",
            "tasks.list",
            "tasks.get",
            "tasks.update",
            "tasks.retry",
            "tasks.cancel",
        ])

        for action in ["create", "list", "get", "update", "retry", "cancel"] {
            let canonicalName = "tasks.\(action)"
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: canonicalName)
                    == canonicalName
            )
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: "task.\(action)")
                    == nil
            )
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: "task_\(action)")
                    == nil
            )
        }
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "tasks") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "agents") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "send_input") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "retry_task") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "cancel_task") == nil)
        #expect(DirectTaskToolAdapter.isTaskToolName("tasks.create"))
        #expect(!DirectTaskToolAdapter.isTaskToolName("task.create"))
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.list",
            allowedToolNames: ["task.list"]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.list",
            allowedToolNames: ["task."]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "task.list",
            allowedToolNames: ["tasks."]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.update",
            allowedToolNames: ["feature.task.update"]
        ))
    }
}

private struct ToolPayloadPropertySets: Sendable {
    let responses: Set<String>
    let chatCompletions: Set<String>
}

private extension DirectToolExecutor {
    /// Builds the wire payloads through the production `RemoteToolWireCatalog`
    /// path, keeping the non-Sendable `[String: Any]` payloads inside the actor
    /// and transferring only their Sendable property-name projection to the test.
    func taskUpdatePayloadPropertiesForTesting(
        sessionID: String
    ) async throws -> ToolPayloadPropertySets {
        let catalog = RemoteToolWireCatalog(
            descriptors: await descriptors(
                allowedToolNames: ["tasks.update"],
                sessionID: sessionID
            )
        )
        return try ToolPayloadPropertySets(
            responses: payloadProperties(catalog.responsesToolPayloads, chatCompletions: false),
            chatCompletions: payloadProperties(catalog.chatCompletionToolPayloads, chatCompletions: true)
        )
    }

    func payloadProperties(
        _ payloads: [[String: Any]],
        chatCompletions: Bool
    ) throws -> Set<String> {
        let payload = try #require(payloads.first)
        let parameters: [String: Any]
        if chatCompletions {
            let function = try #require(payload["function"] as? [String: Any])
            parameters = try #require(function["parameters"] as? [String: Any])
        } else {
            parameters = try #require(payload["parameters"] as? [String: Any])
        }
        return Set(try #require(parameters["properties"] as? [String: Any]).keys)
    }
}
