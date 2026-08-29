import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TaskCommandTests {
    @Test
    func tasksCommandIsVisible() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        #expect(commands.contains("/tasks"))
        #expect(TerminalChat.isKnownSlashCommand("/tasks status"))
    }

    @Test
    func compactTaskGraphRenderingShowsAgentAndDependencies() throws {
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
        let third = TaskRecord(
            id: "task-3",
            title: "Finish",
            order: 3,
            status: .completed,
            createdAt: now,
            updatedAt: now
        )
        let graph = TaskGraphSnapshot(
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [first, second, third],
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
                blockedReason: nil,
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
            TaskRecordView(
                graphID: graph.id,
                graphRevision: graph.revision,
                graphState: graph.state,
                task: third,
                isRunnable: false,
                blockedBy: [],
                blockedReason: nil,
                dependents: []
            ),
        ]

        let rendered = TerminalChat.taskGraphMarkdown(
            graph: graph,
            tasks: views,
            ansiEnabled: true
        )
        #expect(rendered.contains("3 total"))
        #expect(
            rendered.contains(
                "\(TerminalStyle.Status.active)▸ 1 running\(TerminalStyle.reset)"
            )
        )
        #expect(
            rendered.contains(
                "\(TerminalStyle.Status.success)✓ 1 completed\(TerminalStyle.reset)"
            )
        )
        #expect(
            rendered.contains(
                "\(TerminalStyle.Status.inactive)◇ 1 waiting\(TerminalStyle.reset)"
            )
        )
        #expect(rendered.contains("▸ `task-1`"))
        #expect(rendered.contains("agent-worker"))
        #expect(!rendered.contains("in_progress"))
        #expect(rendered.contains("○ `task-2`"))
        #expect(rendered.contains("waits: `task-1`"))

        let plainText = TerminalChat.taskGraphMarkdown(
            graph: graph,
            tasks: views,
            ansiEnabled: false
        )
        #expect(plainText.contains("🫧 Tasks:"))
        #expect(!plainText.contains("\u{1B}"))
        // Vertical layout: each task keeps a single header line and its
        // metadata moves onto an indented detail line below the header.
        let rows = plainText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(rows.contains("   ▸ `task-1`  Implement"))
        #expect(rows.contains("   ○ `task-2`  Validate"))
        #expect(rows.contains("   ✓ `task-3`  Finish"))
        let firstDetailIndex = try #require(
            rows.firstIndex(where: { $0.hasPrefix("     · complexity: `5/10` · agent-worker") })
        )
        let firstHeaderIndex = try #require(rows.firstIndex(of: "   ▸ `task-1`  Implement"))
        #expect(firstDetailIndex == firstHeaderIndex + 1)
        #expect(
            rows.contains("     · complexity: `5/10` · waits: `task-1`")
        )
        // The legacy trailing-metadata layout must not come back.
        #expect(!plainText.contains("Implement — "))
    }

    @Test
    func verticalTaskGraphRenderingIndentsMetadataAndWrapsLongDescriptions() throws {
        let now = Date(timeIntervalSince1970: 10)
        let longTitle = "Implement the vertical task section with a deliberately long title that must wrap"
        let longReason = String(repeating: "waiting for dependencies with a long descriptive run-on reason ", count: 8)
            + "that keeps going"
        let first = TaskRecord(
            id: "task-long",
            title: longTitle,
            order: 1,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
        let second = TaskRecord(
            id: "task-blocked",
            title: "Short",
            order: 2,
            status: .pending,
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
                blockedReason: longReason,
                dependents: []
            ),
            TaskRecordView(
                graphID: graph.id,
                graphRevision: graph.revision,
                graphState: graph.state,
                task: second,
                isRunnable: false,
                blockedBy: [],
                blockedReason: nil,
                dependents: []
            ),
        ]

        let rendered = TerminalChat.taskGraphMarkdown(
            graph: graph,
            tasks: views,
            ansiEnabled: false
        )
        let rows = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Each task owns one header row: marker, id, title.
        let longHeaderIndex = try #require(rows.firstIndex(where: { $0.hasPrefix("   ○ `task-long`  ") }))
        #expect(rows[longHeaderIndex].hasSuffix(longTitle))
        let blockedHeaderIndex = try #require(rows.firstIndex(of: "   ○ `task-blocked`  Short"))

        // Metadata sits on an indented detail line directly below the header.
        let longDetailIndex = try #require(rows.firstIndex(where: { $0.hasPrefix("     · complexity: `5/10` · ") }))
        #expect(longDetailIndex == longHeaderIndex + 1)
        #expect(rows[longDetailIndex].contains(longReason.prefix(20)))
        let blockedDetailIndex = try #require(rows.firstIndex(of: "     · complexity: `5/10`"))
        #expect(blockedDetailIndex == blockedHeaderIndex + 1)

        // The header keeps the full task title: wrapping applies only to the
        // indented metadata line. Every continuation row stays indented past
        // the detail indent so long descriptive lines remain readable.
        let continuationIndices = rows.indices.filter { index in
            index > longDetailIndex
                && index < blockedHeaderIndex
                && rows[index].hasPrefix("       ")
        }
        #expect(!continuationIndices.isEmpty)
        #expect(continuationIndices == Array((longDetailIndex + 1)...(blockedHeaderIndex - 1)))
    }

    @Test
    func taskDetailWrappingPreservesSpacingAndSplitsOverlongTokens() throws {
        let now = Date(timeIntervalSince1970: 10)
        let wrapWidth = max(40, TerminalChat.terminalColumnCount() - 20)
        // Deliberately wider than the current wrap width so the detail
        // renderer must break a single token at the column limit on every TTY.
        let overlongToken = String(repeating: "X", count: wrapWidth * 2)
        let reason = "keep  double  spaces  " + overlongToken + " tail"
        let task = TaskRecord(
            id: "task-detail",
            title: "Blocked",
            order: 1,
            status: .pending,
            createdAt: now,
            updatedAt: now
        )
        let graph = TaskGraphSnapshot(
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [task],
            createdAt: now,
            updatedAt: now
        )
        let views = [
            TaskRecordView(
                graphID: graph.id,
                graphRevision: graph.revision,
                graphState: graph.state,
                task: task,
                isRunnable: false,
                blockedBy: [],
                blockedReason: reason,
                dependents: []
            ),
        ]

        let rendered = TerminalChat.taskGraphMarkdown(
            graph: graph,
            tasks: views,
            ansiEnabled: false
        )
        let rows = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        // Regression 1: no rendered row exceeds the full row budget. The
        // detail prefix is prepended after wrapping, so the first detail row
        // carries 5 leading columns plus the wrap budget itself.
        for row in rows where !row.isEmpty {
            #expect(
                TerminalANSIText.visibleWidth(row) <= 5 + wrapWidth,
                "row exceeds the wrap width: \(row)"
            )
        }

        let headerIndex = try #require(rows.firstIndex(of: "   ○ `task-detail`  Blocked"))
        let detailRows = Array(rows[(headerIndex + 1)...].prefix { $0.hasPrefix("     ") })
        #expect(detailRows.count > 1)

        // Regression 2: internal whitespace runs survive wrapping instead of
        // being collapsed to single spaces past the threshold.
        #expect(detailRows[0].contains("keep  double  spaces"))

        // Regression 3: wrapping is lossless — the detail rows reconstruct the
        // original metadata exactly. The first row carries the shared three-
        // space task indent plus the two-space detail indent; continuation
        // rows carry the three-space join indent plus the four-space hang.
        let detail = detailRows.enumerated().map { index, row in
            String(row.dropFirst(index == 0 ? 5 : 7))
        }.joined()
        #expect(detail == "· complexity: `5/10` · " + reason)
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
            hostedModelID: "remote-community/test",
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
