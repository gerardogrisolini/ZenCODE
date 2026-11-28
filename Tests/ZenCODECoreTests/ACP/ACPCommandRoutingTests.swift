//
//  ACPCommandRoutingTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// Scope the complete test (not just fixture construction): checkpoint writes
/// resolve the support directory again after every suspension.
private struct ACPCommandStorageScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            try await function()
        }
    }
}

@Suite(.serialized, ACPCommandStorageScope())
struct ACPCommandRoutingTests {
    @Test
    func goalWithoutSubAgentsStartsResumesAndIsDiscoverable() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-direct-goal-\(UUID().uuidString)", allowedToolNames: ["local.read"]
        )
        let names = await fixture.bridge.commandNamesForGoalTesting(sessionID: fixture.sessionID)
        // Without the sub-agent tools `/review` and `/plan` stay hidden; `/tasks`
        // reads and controls the graph either way, and the workspace commands
        // `/changes` and `/undo` follow it.
        #expect(names == ["goal", "tasks", "changes", "undo"])
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Preserve direct objective"
        ])
        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.workflow?.state == .awaitingUser)
        #expect(graph.workflow?.originalGoal == "Preserve direct objective")
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "Proceed directly"
        ])
        let prompts = await fixture.backend.recordedPrompts()
        #expect(prompts.contains { $0.contains("Continue the goal workflow") && $0.contains("Proceed directly") })
        #expect(prompts.contains { $0.contains("Continue the active /goal workflow automatically") })
        let resumed = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(resumed.id == graph.id)
        #expect(resumed.workflow?.originalGoal == graph.workflow?.originalGoal)
        #expect(resumed.workflow?.state == .awaitingUser)
        #expect(await fixture.bridge.commandNamesForGoalTesting(sessionID: fixture.sessionID)
            == ["goal", "tasks", "changes", "undo"])
        let expectedGrant = ChatTurnPurpose.workflow(originalGoal: "", graphID: graph.id)
            .additionalToolNames(activePlan: nil)
            .union(["local.read"])
        let grants = await fixture.backend.recordedToolGrants()
        #expect(grants.contains(expectedGrant))
        #expect(grants.allSatisfy { $0?.isSubset(of: expectedGrant) == true })
    }

    @Test
    func directGoalAutomaticallyContinuesUntilGraphCompletionWithoutSubAgents() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-direct-complete-\(UUID().uuidString)", allowedToolNames: ["local.read"]
        )
        await fixture.backend.completeWorkflowDirectly()
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Complete direct work"
        ])
        let prompts = await fixture.backend.recordedPrompts()
        #expect(prompts.count == 3)
        #expect(prompts.dropFirst().allSatisfy { $0.contains("Continue the active /goal workflow automatically") })
        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.state == .completed)
        #expect(graph.workflow?.state == .completed)
        #expect(graph.tasks.count == 1)
        #expect(graph.tasks.first?.attempts.last?.executor == .coordinator)
        #expect(graph.tasks.first?.attempts.last?.status == .completed)
        #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID) == nil)
    }

    /// `/plan` needs the messaging tools on top of the sub-agent ones, so a
    /// session that has only `agent.create`/`agent.wait` sees `/review` but not
    /// `/plan`, which it would refuse. With `agent.message` both are offered.
    @Test
    func planIsAdvertisedOnlyWhenTheSessionCanRunIt() async throws {
        let withoutMessaging = try await makeFixture(
            sessionID: "acp-commands-plan-\(UUID().uuidString)",
            allowedToolNames: ["local.read", "agent.create", "agent.wait"]
        )
        #expect(await withoutMessaging.bridge.commandNamesForGoalTesting(sessionID: withoutMessaging.sessionID)
            == ["goal", "review", "tasks", "changes", "undo"])

        let withMessaging = try await makeFixture(
            sessionID: "acp-commands-plan-message-\(UUID().uuidString)",
            allowedToolNames: ["local.read", "agent.create", "agent.wait", "agent.message"]
        )
        #expect(await withMessaging.bridge.commandNamesForGoalTesting(sessionID: withMessaging.sessionID)
            == ["goal", "review", "plan", "tasks", "changes", "undo"])
    }

    // MARK: - /tasks

    /// A turn that changes the graph publishes the plan while it runs, through
    /// the turn's own presentation, and never sends the same section twice. The
    /// session's first section comes after its reply, as its info and commands
    /// do.
    @Test
    func aTurnThatChangesTheTaskGraphPublishesThePlanWhileItRuns() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-live-\(UUID().uuidString)")
        // The incarnation publishes its first section from its own observer
        // task, which the reply does not wait for.
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.timeline().contains("plan")
        })
        let timeline = fixture.wire.timeline()
        let reply = try #require(timeline.firstIndex(of: "result:1"))
        let firstPlan = try #require(timeline.firstIndex(of: "plan"))
        #expect(firstPlan > reply)

        await fixture.backend.completeWorkflowDirectly()
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Complete the review surface",
        ])
        let statuses = fixture.wire.planStatuses().filter { !$0.isEmpty }
        let contents = fixture.wire.planContents().filter { !$0.isEmpty }
        // The task exists before the turn that completes it, so the client saw
        // it move, and no section repeated the one before it.
        #expect(statuses.count >= 2)
        #expect(statuses.last == ["completed"])
        #expect(!contents.isEmpty)
        #expect(contents.allSatisfy { $0 == ["Complete direct work"] })
        #expect(zip(statuses, statuses.dropFirst()).allSatisfy { $0 != $1 })
        await fixture.bridge.shutdown()
    }

    /// `/tasks` is advertised and answered at once with the graph the terminal
    /// shows, as the plan update that is the client's Tasks section, and never
    /// reaches the model. `status`, `list`, and `ls` read the same graph;
    /// `show` and `get` answer one task.
    @Test
    func tasksCommandAnswersWithTheGraphAndThePlanSectionWithoutReachingTheModel() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-tasks-\(UUID().uuidString)", allowedToolNames: ["local.read"]
        )
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        // Without the sub-agent tools the catalog holds exactly these four.
        #expect(await bridge.commandNamesForGoalTesting(sessionID: sessionID)
            == ["goal", "tasks", "changes", "undo"])

        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [
                TaskDefinition(id: "first", title: "Write the ACP answer"),
                TaskDefinition(id: "second", title: "Show the plan section"),
            ]
        )
        for line in ["/tasks", "/tasks status", "/tasks list", "/tasks ls", "/tasks LS"] {
            try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": line])
            let answer = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
            // The client shows the line it sent: the agent does not echo it.
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk").isEmpty)
            #expect(answer.contains("Tasks:"))
            #expect(answer.contains("Write the ACP answer"))
            #expect(answer.contains("Show the plan section"))
            #expect(fixture.wire.planContents().last == ["Write the ACP answer", "Show the plan section"])
        }

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID, "prompt": "/tasks show first",
        ])
        let detail = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
        #expect(detail.contains("## Task `first`"))
        #expect(detail.contains("Write the ACP answer"))

        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID, "prompt": "/tasks GET first",
        ])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last?.contains("## Task `first`") == true)

        try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "/tasks show"])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last
            == "ZenCODE: /tasks show requires a task id.")

        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID, "prompt": "/tasks show missing",
        ])
        let missing = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
        #expect(missing.hasPrefix("ZenCODE: "))
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.stopReason(for: 1) == "end_turn")
    }

    /// Without a task graph `/tasks` says so and publishes an empty plan, so a
    /// section left over from an earlier graph is cleared.
    @Test
    func tasksCommandWithoutAGraphSaysSoAndClearsThePlanSection() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-empty-\(UUID().uuidString)")
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/tasks",
        ])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["No task graph for this session."])
        #expect(fixture.wire.planContents() == [[]])
    }

    /// `/tasks clear` answers the shared notice and leaves an empty plan
    /// behind; an action the shared command does not know keeps its text and
    /// publishes nothing.
    @Test
    func tasksCommandClearAndUnknownActionKeepTheirOwnAnswers() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-clear-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "only", title: "Only task")]
        )
        try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": "/tasks clear"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["Cleared the session task graphs."])
        #expect(fixture.wire.planContents() == [[]])

        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "/tasks bogus"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last
            == "ZenCODE: Unknown /tasks action 'bogus'. Use status, show, retry, cancel, or clear.")
        // The unknown action published no plan: the empty one is still the last.
        #expect(fixture.wire.planContents() == [[]])
    }

    /// `/tasks retry` and `/tasks cancel` run the shared lifecycle and answer
    /// with the graph they left, and the plan follows it, so the section never
    /// keeps a state the graph no longer has.
    @Test
    func tasksCommandRetryAndCancelAnswerWithTheGraphTheyLeft() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-lifecycle-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [
                TaskDefinition(id: "t1", title: "Retry me"),
                TaskDefinition(id: "t2", title: "Cancel me"),
            ]
        )
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID, taskID: "t1", update: TaskUpdate(status: .inProgress)
        )
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID, taskID: "t1", update: TaskUpdate(status: .failed, error: "boom")
        )

        try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": "/tasks retry t1"])
        #expect(fixture.wire.planContents().last == ["Retry me", "Cancel me"])
        #expect(fixture.wire.planStatuses().last == ["pending", "pending"])

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID, "prompt": "/tasks cancel t2 no longer needed",
        ])
        #expect(fixture.wire.planContents().last == ["Retry me", "[cancelled] Cancel me"])
        #expect(fixture.wire.planStatuses().last == ["pending", "pending"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// The Tasks section follows the graph outside a prompt too: a graph created
    /// or modified while no turn runs reaches the client, as the terminal's and
    /// the host app's observers publish their overview; a change that leaves the
    /// plan as it is does not send it again.
    @Test
    func aGraphChangedOutsideAPromptPublishesThePlanAutomatically() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-idle-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        // The session announces the graph it has when it starts: none here.
        #expect(await ACPTelegramTestSupport.waitUntil { fixture.wire.planContents() == [[]] })

        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "idle", title: "Created outside a prompt")]
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planContents().last == ["Created outside a prompt"]
        })

        // A change that leaves the plan as it is publishes nothing.
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID,
            taskID: "idle",
            update: TaskUpdate(details: "Only the task details changed")
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.wire.planContents() == [[], ["Created outside a prompt"]])

        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID,
            taskID: "idle",
            update: TaskUpdate(status: .inProgress)
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planStatuses().last == ["in_progress"]
        })
        #expect(fixture.wire.planContents() == [[], ["Created outside a prompt"], ["Created outside a prompt"]])
        #expect(fixture.wire.planStatuses() == [[], ["pending"], ["in_progress"]])

        // The plan the turn's presentation would send next is already
        // presented: a turn publishes it only when the graph changes again.
        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "Hello"])
        #expect(fixture.wire.plans().count == 3)
        await bridge.shutdown()
    }

    /// A closed session publishes nothing more: the incarnation's observer is
    /// cancelled with it, so a graph changed afterwards never reaches the client
    /// of a session it no longer has.
    @Test
    func aClosedSessionPublishesNoFurtherPlan() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-closed-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "gone", title: "Before the close")]
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planContents().last == ["Before the close"]
        })

        try await bridge.close(id: .number(2), params: ["sessionId": sessionID])
        #expect(await bridge.testSessionCount() == 0)
        let afterClose = fixture.wire.plans().count

        _ = try? await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "later", title: "After the close")]
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.wire.plans().count == afterClose)
        await bridge.shutdown()
    }

    /// The graph a turn changed reaches the client before the turn's reply:
    /// nothing of the session follows the stop reason the client answers.
    @Test
    func thePlanOfTheTurnPrecedesItsReply() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-plan-order-\(UUID().uuidString)")
        await fixture.backend.completeWorkflowDirectly()
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Complete the review surface",
        ])
        let timeline = fixture.wire.timeline()
        let reply = try #require(timeline.firstIndex(of: "result:2"))
        let planIndices = timeline.enumerated()
            .filter { $0.element == "plan" }
            .map(\.offset)
        let lastPlan = try #require(planIndices.last)
        #expect(lastPlan < reply)
        await fixture.bridge.shutdown()
    }

    /// The observer belongs to the incarnation, not to its configuration: a
    /// same-epoch reconstruction (a refresh, an `@mention`, a reconfiguration)
    /// keeps the running one instead of starting a second.
    @Test
    func aSameEpochReconstructionKeepsTheRunningObserver() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-inherit-\(UUID().uuidString)")
        #expect(await fixture.bridge.taskGraphObserverSurvivesReconstruction(
            sessionID: fixture.sessionID
        ))
        await fixture.bridge.shutdown()
    }

    /// A turn the model ended by asking for tools for the session's maximum
    /// number of rounds answers with the ACP stop reason for it, not with a
    /// JSON-RPC error response: the turn ended, the request did not fail.
    @Test
    func theToolRoundLimitEndsTheTurnAsAStopReason() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-tool-round-limit-\(UUID().uuidString)",
            allowedToolNames: ["local.read"]
        )
        await fixture.backend.failNextTurn(with: .tooManyToolRounds(3))
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "Keep reading the files"
        ])
        #expect(fixture.wire.stopReason(for: 1) == "max_turn_requests")
    }

    /// The fixture of the command tests: a bridge on the scripted backend, its
    /// wire, and its working directory, with no session yet.
    private func makeBridge(
        sessionID: String,
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles()
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        workingDirectory: URL
    ) {
        let workingDirectory = AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ScriptedACPCommandBackend()
        let wire = ACPCommandWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: availableAgents,
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                ),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        return (bridge, backend, wire, workingDirectory)
    }

    /// A bridge whose session is installed directly, without `session/new`:
    /// there is no incarnation task-graph observer, so only a prompt and the
    /// commands publish the plan.
    func makeFixture(
        sessionID: String,
        allowedToolNames: Set<String>? = nil,
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles(),
        history: [AgentRuntimeMessage] = []
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        sessionID: String
    ) {
        let (bridge, backend, wire, workingDirectory) = try await makeBridge(
            sessionID: sessionID,
            availableAgents: availableAgents
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "ACP command routing test",
            cacheKey: nil,
            history: history,
            allowedToolNames: allowedToolNames
        )
        try await bridge.sessionRunner.createSession(
            configuration: sessionConfiguration
        )
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }

    /// A bridge whose session a `session/new` created, as a client creates it:
    /// the incarnation's task-graph observer runs, so the plan follows the graph
    /// outside a prompt too.
    private func makeLiveFixture(
        sessionID: String
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        sessionID: String
    ) {
        let (bridge, backend, wire, workingDirectory) = try await makeBridge(sessionID: sessionID)
        try await bridge.newSession(id: .number(1), params: ["cwd": workingDirectory.path])
        let liveSessionID = try #require(await bridge.testAnySessionID())
        return (bridge, backend, wire, liveSessionID)
    }
}

extension ZenCODEACPBridge {
    fileprivate func commandNamesForGoalTesting(sessionID: String) -> [String] {
        availableCommandsForTesting(sessionID: sessionID).compactMap {
            $0.objectValue?["name"]?.stringValue
        }
    }

    fileprivate func availableCommandsForTesting(sessionID: String) -> [JSONValue] {
        guard let session = sessions[sessionID] else { return [] }
        return availableCommandsUpdate(for: session).objectValue?["availableCommands"]?.arrayValue ?? []
    }

    /// Whether a same-epoch reconstruction of `sessionID` inherits the running
    /// task-graph observer, as every refresh, `@mention`, and reconfiguration
    /// does.
    fileprivate func taskGraphObserverSurvivesReconstruction(sessionID: String) -> Bool {
        guard let live = sessions[sessionID],
              let observer = live.taskGraphObserver else {
            return false
        }
        let rebuilt = sessionState(
            configuration: live.configuration,
            selectedAgent: live.selectedAgent,
            inheriting: live
        )
        return rebuilt.epoch == live.epoch
            && rebuilt.taskGraphObserver == observer
            && rebuilt.taskPresentation === live.taskPresentation
    }
}
