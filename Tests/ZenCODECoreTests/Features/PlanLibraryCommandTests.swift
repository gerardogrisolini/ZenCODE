//
//  PlanLibraryCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct PlanLibraryCommandTests {
    private func makeTemp() throws -> (
        root: URL,
        support: URL,
        working: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PlanLibraryCommandTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let working = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: working,
            withIntermediateDirectories: true
        )
        return (root, support, working)
    }

    private func makeSavedPlan(
        id: String,
        goal: String,
        savedAt: Date
    ) -> TaskGraphSavedPlan {
        TaskGraphSavedPlan(
            plan: TerminalSessionPlan(
                id: id,
                originalGoal: goal,
                consolidatedText: "\(goal). Inspect, implement, and validate.",
                createdAt: savedAt,
                points: [TerminalSessionPlanPoint(id: "\(id)-1", text: "Do \(goal)")]
            ),
            savedAt: savedAt,
            savingAgentName: "Planner"
        )
    }

    @discardableResult
    private func seedLibrary(
        support: URL,
        working: URL,
        savedPlans: [TaskGraphSavedPlan]
    ) async throws -> String {
        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let seeder = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        try await seeder.registerSession(
            id: librarySessionID,
            workingDirectory: working
        )
        for savedPlan in savedPlans {
            _ = try await seeder.savePlanDraft(
                savedPlan,
                sessionID: librarySessionID,
                tasks: [
                    TaskDefinition(
                        id: "\(savedPlan.plan.id)-1",
                        title: "Do \(savedPlan.plan.originalGoal)"
                    )
                ]
            )
        }
        return librarySessionID
    }

    private func makeTerminal(
        workingDirectory: URL,
        supportDirectory: URL
    ) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        // An injected runner with an isolated store keeps this suite free of
        // process-global support-directory mutations (and their races).
        let runner = AgentCoreSessionRunner(
            taskGraphStore: SessionTaskGraphStore(
                supportDirectoryURL: supportDirectory
            )
        )
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }

    @Test
    func listAndDeleteAllThroughTheChatCommandSurface() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let librarySessionID = try await seedLibrary(
            support: support,
            working: working,
            savedPlans: [
                makeSavedPlan(
                    id: "plan-aaaaaaaa-1111",
                    goal: "First plan",
                    savedAt: Date(timeIntervalSince1970: 100)
                ),
                makeSavedPlan(
                    id: "plan-bbbbbbbb-2222",
                    goal: "Second plan",
                    savedAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        )

        let terminal = try makeTerminal(
            workingDirectory: working,
            supportDirectory: support
        )
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan LIST")))
        #expect(isContinueChat(await terminal.handlePlanCommand("/plan DELETE all")))

        // The deletion is durable on disk, not just in the chat process.
        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let verifier = SessionTaskOrchestrator(store: store)
        #expect(
            await verifier.savedTaskPlans(workingDirectory: working).isEmpty
        )
        #expect(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            ) == nil
        )
    }

    @Test
    func deleteByUniquePrefixRemovesOnlyTheMatchingPlan() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await seedLibrary(
            support: support,
            working: working,
            savedPlans: [
                makeSavedPlan(
                    id: "plan-aaaaaaaa-1111",
                    goal: "First plan",
                    savedAt: Date(timeIntervalSince1970: 100)
                ),
                makeSavedPlan(
                    id: "plan-bbbbbbbb-2222",
                    goal: "Second plan",
                    savedAt: Date(timeIntervalSince1970: 200)
                ),
            ]
        )

        let terminal = try makeTerminal(
            workingDirectory: working,
            supportDirectory: support
        )
        #expect(
            isContinueChat(await terminal.handlePlanCommand("/plan DELETE plan-bbbb"))
        )

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let verifier = SessionTaskOrchestrator(store: store)
        let remaining = await verifier.savedTaskPlans(workingDirectory: working)
        #expect(remaining.map(\.graph.id) == ["plan-aaaaaaaa-1111"])
    }

    @Test
    func deleteWithUnknownTargetLeavesTheLibraryUnchanged() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await seedLibrary(
            support: support,
            working: working,
            savedPlans: [
                makeSavedPlan(
                    id: "plan-aaaaaaaa-1111",
                    goal: "First plan",
                    savedAt: Date(timeIntervalSince1970: 100)
                )
            ]
        )

        let terminal = try makeTerminal(
            workingDirectory: working,
            supportDirectory: support
        )
        #expect(
            isContinueChat(await terminal.handlePlanCommand("/plan DELETE plan-zzzz"))
        )

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let verifier = SessionTaskOrchestrator(store: store)
        #expect(
            await verifier.savedTaskPlans(workingDirectory: working)
                .map(\.graph.id) == ["plan-aaaaaaaa-1111"]
        )
    }
}
