//
//  ZenToolbarAvailabilityTests.swift
//  ZenAppSessionTests
//
//  What the window says it would refuse now (`refusesNow(_:)`), which the
//  toolbar reads to show its buttons disabled: nothing while the window is
//  idle, the commands that do not run while a prompt is running while a line
//  runs (a turn, a command waiting on a menu, a turn adopted from Telegram),
//  and nothing again once the line ends. Asking changes nothing, and the
//  refusal itself is unchanged.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenToolbarAvailabilityTests {
    /// The commands of the toolbar that the window refuses while a line runs:
    /// the buttons, then the items of the Changes menu.
    private static let refusedWhileRunning = [
        "/agents", "/models", "/think", "/tools", "/skills",
        "/changes", "/changes diff", "/undo", "/review",
    ]
    /// The commands of the toolbar that run beside a running line.
    private static let allowedWhileRunning = ["/tasks", "/artifacts"]
    private static let toolbarCommands = refusedWhileRunning + allowedWhileRunning

    // MARK: - A turn

    @Test("An idle window refuses no command of the toolbar")
    func idleRefusesNothing() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            #expect(Self.refused(by: window).isEmpty)
            // Even a line that does not exist is not refused while nothing runs.
            #expect(!window.refusesNow("/nope"))
        }
    }

    @Test("While a turn runs, the commands that do not run during a prompt are refused and /tasks and /artifacts are not; once it ends, none is")
    func aRunningTurnRefusesTheOtherCommands() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let gate = ZenGate()
            window.turnDidReserve = { await gate.pass() }
            window.draft = "Gated"
            window.submitDraft()
            await waitUntil("the turn reserved its prompt") { await gate.reached }
            #expect(window.isBusy)

            #expect(Self.refused(by: window) == Self.refusedWhileRunning)
            for command in Self.allowedWhileRunning {
                #expect(!window.refusesNow(command), "\(command)")
            }
            // A prompt waits in the queue, and an unknown command is refused.
            #expect(!window.refusesNow("Another prompt"))
            #expect(window.refusesNow("/nope"))
            // The arguments decide, as in the terminal.
            #expect(!window.refusesNow("/tasks list"))
            #expect(window.refusesNow("/tasks retry t1"))

            await gate.open()
            #expect(await window.waitUntilIdle())
            window.turnDidReserve = nil
            #expect(!window.isBusy)
            #expect(Self.refused(by: window).isEmpty)
            #expect(await backend.prompts == ["Gated"])
        }
    }

    @Test("Asking adds no row to the transcript, selects no tab, and leaves the queue alone; the refusal itself is unchanged")
    func askingHasNoSideEffects() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let gate = ZenGate()
            window.turnDidReserve = { await gate.pass() }
            window.draft = "Gated"
            window.submitDraft()
            await waitUntil("the turn reserved its prompt") { await gate.reached }
            window.draft = "Queued"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["Queued"])

            let rows = window.transcript.map(\.id)
            let queue = window.queuedLines.map(\.id)
            for _ in 0..<3 {
                #expect(Self.refused(by: window) == Self.refusedWhileRunning)
            }
            #expect(window.transcript.map(\.id) == rows)
            #expect(window.queuedLines.map(\.id) == queue)
            #expect(window.pendingRequest == nil)
            #expect(window.selectedTab == .chat)

            // The window still refuses the command, with the terminal's message.
            #expect(!window.route("/models"))
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/models' is unavailable while a prompt is running.",
                isFailure: true
            ))
            #expect(!window.route("/undo"))
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/undo' is unavailable while a prompt is running.",
                isFailure: true
            ))
            #expect(window.transcript.count == rows.count + 2)

            await gate.open()
            window.turnDidReserve = nil
            #expect(await window.waitUntilIdle())
        }
    }

    // MARK: - A command waiting on a menu

    @Test("While a command waits on its menu, the toolbar's commands are refused as for a turn, and enabled again when the menu is answered")
    func aCommandWaitingOnAMenuRefusesTheOtherCommands() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            #expect(Self.refused(by: window).isEmpty)

            window.run("/models", menuAnchor: ZenMenuAnchor(id: "/models"))
            #expect(await eventually {
                if case .chooseOne? = window.pendingRequest?.kind { return true }
                return false
            })
            // The menu of /models opens while /models itself is refused.
            #expect(window.isBusy)
            #expect(Self.refused(by: window) == Self.refusedWhileRunning)
            #expect(window.refusesNow("/models"))

            let request = try #require(window.pendingRequest)
            window.answer(request.id, with: nil)
            #expect(await eventually { window.pendingRequest == nil })
            #expect(await window.waitUntilIdle())
            #expect(Self.refused(by: window).isEmpty)
        }
    }

    @Test("Whether the window refuses a command follows the line: what a window answers, the toolbar shows")
    func refusalFollowsTheLine() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            // Waiting lines but no line running: the line queues, it is not refused.
            window.queuedLines = [ZenQueuedLine(text: "Next")]
            #expect(Self.refused(by: window).isEmpty)
            window.queuedLines = []

            window.isBusy = true
            for command in Self.toolbarCommands {
                let route = ZenLineRoute.route(
                    for: command,
                    isLineRunning: window.isBusy,
                    hasQueuedLines: false,
                    registry: ZenAppCommands.registry,
                    context: window.commandContext
                )
                var isRefused = false
                if case .refuse = route { isRefused = true }
                #expect(window.refusesNow(command) == isRefused, "\(command)")
            }
            window.isBusy = false
            #expect(Self.refused(by: window).isEmpty)
        }
    }

    // MARK: - A turn adopted from Telegram

    @Test("While a turn adopted from Telegram runs, the commands are refused as for a turn; once its prompt is released, they are enabled again")
    func anAdoptedTurnRefusesTheOtherCommands() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            window.adoptedTelegramTurnSleep = Self.quickSleep

            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            window.watchAdoptedTelegramTurn(reservation.promptID)
            #expect(!window.isBusy)
            #expect(Self.refused(by: window) == Self.refusedWhileRunning)
            for command in Self.allowedWhileRunning {
                #expect(!window.refusesNow(command), "\(command)")
            }

            await Self.releasePrompt(reservation, in: runtime.sessionHost)
            #expect(await window.waitUntilIdle())
            #expect(window.adoptedTelegramPromptID == nil)
            #expect(Self.refused(by: window).isEmpty)
        }
    }

    // MARK: - Observation

    @Test("The end of a turn adopted from Telegram changes what refusesNow reads: the observers hear it")
    func theEndOfAnAdoptedTurnInvalidatesTheObservers() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            window.adoptedTelegramTurnSleep = Self.quickSleep

            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            window.watchAdoptedTelegramTurn(reservation.promptID)
            // What the toolbar's buttons and Changes menu read.
            let button = ZenObservationCounter { _ = window.refusesNow("/models") }
            let menu = ZenObservationCounter {
                _ = ["/changes", "/changes diff", "/undo", "/review"].allSatisfy { window.refusesNow($0) }
            }
            #expect(window.refusesNow("/models"))
            // The observers settle on the adopted turn, which still runs.
            try await Task.sleep(for: .milliseconds(50))
            let buttonBefore = button.count
            let menuBefore = menu.count

            // Nothing but the adopted turn changes: neither busy, queue, nor context.
            #expect(!window.isBusy)
            await Self.releasePrompt(reservation, in: runtime.sessionHost)
            #expect(await eventually { button.count > buttonBefore && menu.count > menuBefore })
            #expect(!window.refusesNow("/models"))
        }
    }

    @Test("A write of the adopted prompt invalidates an observation of refusesNow, in both directions")
    func writingTheAdoptedPromptInvalidatesTheObservation() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let observed = ZenObservationCounter { _ = window.refusesNow("/models") }

            window.adoptedTelegramPromptID = UUID()
            #expect(await eventually { observed.count == 1 })
            #expect(window.refusesNow("/models"))

            window.adoptedTelegramPromptID = nil
            #expect(await eventually { observed.count == 2 })
            #expect(!window.refusesNow("/models"))
        }
    }

    // MARK: - Helpers

    /// The commands of the toolbar `window` would refuse now, in order.
    private static func refused(by window: ZenWindowSession) -> [String] {
        toolbarCommands.filter { window.refusesNow($0) }
    }

    /// A short real sleep between two reads of an adopted turn's reservation.
    private static let quickSleep: @Sendable (Duration) async throws -> Void = { _ in
        try await Task.sleep(for: .milliseconds(5))
    }

    @ChatSessionActor
    private static func reservePrompt(in sessionHost: ChatSessionHost, slotID: ChatSlotID) throws -> ChatPromptReservation {
        try sessionHost.reservePrompt(in: slotID)
    }

    @ChatSessionActor
    private static func releasePrompt(_ reservation: ChatPromptReservation, in sessionHost: ChatSessionHost) {
        sessionHost.releasePrompt(reservation)
    }

    /// Polls `condition` on the main actor until it holds or 10 s pass.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A runtime over the scripted backend, a hosted configuration, and a
    /// temporary support directory and workspace.
    private func withRuntime(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-toolbar-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await Self.compose(workspace: workspace, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "zen-app-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(
                    id: "zen-app-model",
                    kind: .remoteAPI,
                    modelID: "local/zen-app-model"
                ),
            ],
            workingDirectory: workspace,
            appMode: true
        )
        let backend = ZenScriptedBackend()
        let runtime = await ZenAppRuntime(
            configuration: configuration,
            featureRuntime: nil,
            userHomeDirectoryURL: nil,
            backendFactory: { _, _ in backend },
            openExternal: { _ in }
        )
        do {
            try await body(runtime, backend, workspace)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}
