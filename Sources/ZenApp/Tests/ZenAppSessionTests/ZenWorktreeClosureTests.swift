//
//  ZenWorktreeClosureTests.swift
//  ZenAppSessionTests
//
//  How the app closes the worktree of a `--worktree` launch: the repository
//  is read once, a decision shuts the runtime down before the worktree is
//  closed, only the first decision counts, and keeping the worktree needs no
//  inspection. The runtime has a closure only for a `--worktree` launch.
//

import Foundation
import Testing
import ToolCore
import ZenAppSession
import ZenCODECore

@Suite("Worktree closure")
@MainActor
struct ZenWorktreeClosureTests {
    /// One call of the injected `perform`.
    struct Performed: Equatable {
        let action: AgentWorktreeManager.ClosingAction
        let mainRoot: URL
        let mainBranch: String
        let hasUncommittedChanges: Bool
    }

    /// What the injected steps ran, in order, and the phase each one saw.
    @MainActor
    final class Record {
        var events: [String] = []
        var phases: [ZenWorktreeClosure.Phase] = []
        var performed: [Performed] = []
        var inspections = 0
        weak var closure: ZenWorktreeClosure?
    }

    struct InspectFailure: LocalizedError {
        var errorDescription: String? { "not a Git repository" }
    }

    private static let worktree = AgentWorktree(
        name: "feature",
        directory: URL(filePath: "/tmp/zen-worktrees/feature/project", directoryHint: .isDirectory)
    )
    private static let inspection = AgentWorktreeManager.Inspection(
        mainRoot: URL(filePath: "/tmp/project", directoryHint: .isDirectory),
        mainBranch: "main",
        hasUncommittedChanges: true
    )
    private static let outcome = AgentWorktreeManager.ClosingOutcome(succeeded: true, lines: ["done"])

    /// A closure over `worktree` whose steps `record` follows; the shutdown
    /// waits at `gate` when given.
    private func makeClosure(
        record: Record,
        inspecting inspected: Result<AgentWorktreeManager.Inspection, InspectFailure> = .success(inspection),
        shutdownGate gate: ZenGate? = nil,
        outcome: AgentWorktreeManager.ClosingOutcome = outcome
    ) -> ZenWorktreeClosure {
        let closure = ZenWorktreeClosure(
            worktree: Self.worktree,
            shutdown: {
                record.events.append("shutdown")
                if let phase = record.closure?.phase {
                    record.phases.append(phase)
                }
                await gate?.pass()
            },
            inspect: { _ in
                record.inspections += 1
                return try inspected.get()
            },
            perform: { action, _, inspection in
                record.events.append("perform")
                if let phase = record.closure?.phase {
                    record.phases.append(phase)
                }
                record.performed.append(Performed(
                    action: action,
                    mainRoot: inspection.mainRoot,
                    mainBranch: inspection.mainBranch,
                    hasUncommittedChanges: inspection.hasUncommittedChanges
                ))
                return outcome
            }
        )
        record.closure = closure
        return closure
    }

    @Test("a decision shuts the runtime down, then closes the worktree with the inspection")
    func shutdownThenPerform() async {
        let record = Record()
        let failed = AgentWorktreeManager.ClosingOutcome(succeeded: false, lines: ["merge conflict"])
        let closure = makeClosure(record: record, outcome: failed)
        await closure.load()
        await closure.decide(.merge)

        #expect(record.events == ["shutdown", "perform"])
        #expect(record.phases == [.running(.merge), .running(.merge)])
        #expect(record.performed == [Performed(
            action: .merge,
            mainRoot: Self.inspection.mainRoot,
            mainBranch: "main",
            hasUncommittedChanges: true
        )])
        #expect(closure.phase == .finished(failed))
        #expect(!closure.isPending)
        #expect(!closure.isRunning)
    }

    @Test("the phase goes from choosing to running to finished, and only the first decision counts")
    func onlyTheFirstDecisionCounts() async {
        let record = Record()
        let gate = ZenGate()
        let closure = makeClosure(record: record, shutdownGate: gate)
        await closure.load()
        #expect(closure.phase == .choosing)
        #expect(closure.isPending)
        #expect(!closure.isRunning)

        let decision = Task { await closure.decide(.discard) }
        await waitUntil("the shutdown runs") { await gate.reached }
        #expect(closure.phase == .running(.discard))
        #expect(!closure.isPending)
        #expect(closure.isRunning)

        // A second decision while the first one runs is ignored at once.
        await closure.decide(.keep)
        #expect(closure.phase == .running(.discard))

        await gate.open()
        await decision.value
        #expect(closure.phase == .finished(Self.outcome))

        // And once it ended.
        await closure.decide(.merge)
        #expect(closure.phase == .finished(Self.outcome))
        #expect(record.events == ["shutdown", "perform"])
        #expect(record.performed.map(\.action) == [.discard])
    }

    @Test("without an inspection, keeping still works while merging and removing are ignored")
    func keepWithoutAnInspection() async {
        let record = Record()
        let closure = makeClosure(record: record, inspecting: .failure(InspectFailure()))
        await closure.load()
        #expect(closure.inspection == nil)
        #expect(closure.loadFailure == "Could not inspect the worktree feature: not a Git repository")

        await closure.decide(.merge)
        await closure.decide(.discard)
        #expect(closure.phase == .choosing)
        #expect(record.events.isEmpty)

        await closure.decide(.keep)
        #expect(record.events == ["shutdown", "perform"])
        // `.keep` reads no inspection: a placeholder stands in.
        #expect(record.performed == [Performed(
            action: .keep,
            mainRoot: Self.worktree.directory,
            mainBranch: "feature",
            hasUncommittedChanges: false
        )])
        #expect(closure.phase == .finished(Self.outcome))
    }

    @Test("keeping works before the repository was read; merging does not")
    func keepBeforeTheLoad() async {
        let record = Record()
        let closure = makeClosure(record: record)
        await closure.decide(.merge)
        #expect(closure.phase == .choosing)
        await closure.decide(.keep)
        #expect(record.performed.map(\.action) == [.keep])
        #expect(closure.phase == .finished(Self.outcome))
        // A load after the decision reads nothing.
        await closure.load()
        #expect(record.inspections == 0)
        #expect(closure.inspection == nil)
    }

    @Test("the repository is read once")
    func loadsOnce() async {
        let record = Record()
        let closure = makeClosure(record: record)
        await closure.load()
        await closure.load()
        #expect(record.inspections == 1)
        #expect(closure.inspection?.mainBranch == "main")
        #expect(closure.inspection?.hasUncommittedChanges == true)
        #expect(closure.loadFailure == nil)
    }

    @Test("the operator is asked once")
    func requestsOnce() {
        let closure = makeClosure(record: Record())
        #expect(!closure.isRequested)
        closure.request()
        closure.request()
        #expect(closure.isRequested)
        #expect(closure.isPending)
    }

    @Test("the production steps keep the worktree without reading Git")
    func productionKeep() async {
        let record = Record()
        let closure = ZenWorktreeClosure(
            worktree: Self.worktree,
            shutdown: { record.events.append("shutdown") }
        )
        await closure.decide(.keep)
        #expect(record.events == ["shutdown"])
        guard case let .finished(outcome) = closure.phase else {
            Issue.record("The closing did not finish: \(closure.phase)")
            return
        }
        #expect(outcome.succeeded)
        #expect(outcome.lines == [
            "Worktree feature kept at \(Self.worktree.directory.path). Resume it with: zen --worktree feature"
        ])
    }
}

@Suite("Runtime worktree closure")
@MainActor
struct ZenRuntimeWorktreeClosureTests {
    @Test("a runtime without --worktree has no worktree closure")
    func noWorktree() async throws {
        try await withSupportDirectory { workspace in
            let configuration = try AgentConfiguration(
                hostedModelID: "zen-app-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [Self.model],
                workingDirectory: workspace,
                appMode: true
            )
            let runtime = await Self.makeRuntime(configuration: configuration)
            #expect(runtime.worktreeClosure == nil)
            await runtime.shutdown()
        }
    }

    @Test("a --worktree launch has a closure whose decision shuts the runtime down")
    func worktreeLaunch() async throws {
        try await withSupportDirectory { workspace in
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [Self.model], selectedModelID: Self.model.id),
                to: AgentSettingsManifestStore.settingsURL()
            )
            try AgentProfileStore.save(AgentProfileStore.defaultProfiles())
            let configuration = try AgentConfiguration(arguments: [
                "ZenCODE", "--worktree", "feature", "--working-directory", workspace.path
            ])
            let runtime = await Self.makeRuntime(configuration: configuration)
            let closure = try #require(runtime.worktreeClosure)
            #expect(closure.worktree.name == "feature")
            #expect(closure.worktree.directory == configuration.workingDirectory)
            #expect(closure.isPending)
            #expect(!closure.isRequested)
            #expect(!runtime.isShutDown)

            // Keeping reads no Git: the workspace needs no repository.
            await closure.decide(.keep)
            #expect(runtime.isShutDown)
            guard case let .finished(outcome) = closure.phase else {
                Issue.record("The closing did not finish: \(closure.phase)")
                return
            }
            #expect(outcome.succeeded)
        }
    }

    private static let model = AgentSettingsModelManifest(
        id: "zen-app-model",
        kind: .remoteAPI,
        modelID: "local/zen-app-model"
    )

    private static func makeRuntime(configuration: AgentConfiguration) async -> ZenAppRuntime {
        let backend = ZenScriptedBackend()
        return await ZenAppRuntime(
            configuration: configuration,
            featureRuntime: nil,
            userHomeDirectoryURL: nil,
            backendFactory: { _, _ in backend },
            openExternal: { _ in }
        )
    }

    /// Runs `body` with a temporary support directory, and passes it a
    /// temporary workspace.
    private func withSupportDirectory(
        _ body: @escaping @MainActor @Sendable (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-worktree-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await body(workspace)
        }
    }
}
