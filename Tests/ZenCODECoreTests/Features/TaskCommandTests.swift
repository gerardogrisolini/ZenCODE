import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TaskCommandTests {
    @Test
    func tasksCommandIsVisible() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        #expect(commands.contains("/tasks"))
        #expect(TerminalChat.isKnownSlashCommand("/tasks status"))
    }

    @Test
    func compactTaskGraphRenderingShowsAgentAndDependencies() {
        let now = Date(timeIntervalSince1970: 10)
        let attempt = TaskAttempt(
            id: "attempt-1",
            ordinal: 1,
            agentID: "agent-worker",
            executor: .subAgent,
            status: .running,
            startedAt: now
        )
        let first = TaskRecord(
            id: "task-1",
            title: "Implement",
            order: 1,
            status: .inProgress,
            activeAttemptID: attempt.id,
            attempts: [attempt],
            createdAt: now,
            updatedAt: now
        )
        let second = TaskRecord(
            id: "task-2",
            title: "Validate",
            order: 2,
            dependsOn: ["task-1"],
            createdAt: now,
            updatedAt: now
        )
        let graph = TaskGraphSnapshot(
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [first, second],
            createdAt: now,
            updatedAt: now
        )
        let views = [
            TaskRecordView(
                graphID: graph.id,
                graphRevision: graph.revision,
                graphState: graph.state,
                task: first,
                isRunnable: false,
                blockedBy: [],
                blockedReason: "task status is in_progress",
                dependents: ["task-2"]
            ),
            TaskRecordView(
                graphID: graph.id,
                graphRevision: graph.revision,
                graphState: graph.state,
                task: second,
                isRunnable: false,
                blockedBy: ["task-1"],
                blockedReason: "waiting for dependencies: task-1",
                dependents: []
            ),
        ]

        let rendered = TerminalChat.taskGraphMarkdown(graph: graph, tasks: views)
        #expect(rendered.contains("▸ `task-1`"))
        #expect(rendered.contains("agent-worker"))
        #expect(rendered.contains("○ `task-2`"))
        #expect(rendered.contains("waits for: task-1"))
    }

    @Test
    func tasksRetryAndCancelControlTheGraph() async throws {
        let terminal = try makeTerminal()
        let orchestrator = await terminal.sessionRunner.taskOrchestrator
        _ = try await orchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "A")]
        )
        let first = try #require(try await orchestrator.claimTasks(
            sessionID: terminal.sessionID,
            claims: [TaskClaim(taskID: "task-a", agentID: "worker")]
        ).first)
        _ = try await orchestrator.failAttempt(
            sessionID: terminal.sessionID,
            taskID: "task-a",
            attemptID: first.attemptID,
            error: "failed"
        )

        await terminal.handleTasksCommand("/tasks retry task-a")
        #expect(try await orchestrator.task(
            sessionID: terminal.sessionID, taskID: "task-a"
        ).task.status == .pending)

        _ = try await orchestrator.claimTasks(
            sessionID: terminal.sessionID,
            claims: [TaskClaim(taskID: "task-a", agentID: "worker-2")]
        )
        await terminal.handleTasksCommand("/tasks cancel task-a user requested")
        #expect(try await orchestrator.task(
            sessionID: terminal.sessionID, taskID: "task-a"
        ).task.status == .cancelled)
    }

    @Test
    func subAgentOverviewShowsTaskAndAttempt() {
        let now = Date(timeIntervalSince1970: 10)
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-1",
            rootSessionID: "root",
            taskID: "task-1",
            taskAttemptID: "attempt-1",
            taskAttemptOrdinal: 2,
            name: "worker",
            role: "worker",
            isolationMode: .implementation,
            status: .running,
            pending: true,
            latestOutput: nil,
            latestError: nil,
            createdAt: now,
            updatedAt: now
        )

        let rendered = TerminalANSIText.stripANSI(
            TerminalChat.renderSubAgentOverview([snapshot])
        )
        #expect(rendered.contains("task: task-1"))
        #expect(rendered.contains("attempt: 2"))
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-task-command", isDirectory: true)
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
    }
}
