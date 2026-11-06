//
//  ZenTelegramWindowTests.swift
//  ZenAppSessionTests
//
//  `/telegram` in a window over a scripted backend, without any network: the
//  command hidden without Telegram in the settings, its status, `off` without
//  a link and its usage with Telegram configured, and, through the window's
//  internal seams, a dormant window and a turn adopted from Telegram. No test
//  runs `/telegram on` against a configured manifest.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenTelegramWindowTests {
    /// The host's dormant refusal, without its trailing newline.
    private static let dormantRefusal = ZenTranscriptItem.Content.local(
        text: "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.",
        isFailure: true
    )
    private static let stopped = ZenTranscriptItem.Content.local(
        text: "Telegram remote control stopped.",
        isFailure: false
    )
    private static let unavailableWhileRunning = ZenTranscriptItem.Content.local(
        text: "ZenCODE: command '/telegram' is unavailable while a prompt is running.",
        isFailure: true
    )

    // MARK: - Without Telegram

    @Test("Without Telegram in the settings, /telegram is hidden and every /telegram line answers as an unknown command")
    func hiddenWithoutSettings() async throws {
        try await withRuntime(telegramConfigured: false) { runtime, backend, workspace in
            #expect(!ZenAppCommands.isTelegramConfigured())
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(!window.commandContext.contains(ZenAppCommands.telegramEnabled))
            #expect(!window.commandDescriptors.contains { $0.command == "/telegram" })
            #expect(window.commandDescriptors.last?.command == "/exit")

            for line in ["/telegram", "/telegram on", "/telegram off"] {
                window.draft = line
                window.submitDraft()
                #expect(await window.waitUntilIdle())
                #expect(await eventually {
                    window.transcript.last?.content == .notice(.unknownCommand(line: line))
                }, "\(line)")
            }
            #expect(ChatSessionNoticeText.text(for: .unknownCommand(line: "/telegram on"))
                == "ZenCODE: unknown command '/telegram'.\n")
            #expect(!window.isDrivenFromTelegram)
            #expect(await runtime.sessionHost.telegramChannel(in: window.slotID) == nil)
            #expect(await backend.prompts.isEmpty)
        }
    }

    // MARK: - With Telegram, without a link

    @Test("With Telegram in the settings, /telegram shows the status, /telegram off without a link says it stopped, other arguments answer the usage")
    func configuredWithoutALink() async throws {
        try await withRuntime(telegramConfigured: true) { runtime, backend, workspace in
            #expect(ZenAppCommands.isTelegramConfigured())
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.commandDescriptors.contains { $0.command == "/telegram" } })
            #expect(window.commandContext.contains(ZenAppCommands.telegramEnabled))
            #expect(window.commandDescriptors.map(\.command).suffix(3) == ["/telegram", "/voice", "/exit"])

            // The status: the host's inactive status, since no channel exists.
            let inactive = await runtime.sessionHost.telegramStatusText(in: window.slotID)
            window.draft = "/telegram"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.contains { $0.content == .commandLine("/telegram") })
            #expect(window.transcript.last?.content == .local(
                text: ZenWindowSession.withoutTrailingNewlines(inactive),
                isFailure: false
            ))

            // `off` without a link, in any case.
            window.draft = "/telegram Off"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.last?.content == Self.stopped)

            window.draft = "/telegram foo"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.last?.content == .local(text: "Usage: /telegram [on|off]", isFailure: false))

            #expect(!window.isDrivenFromTelegram)
            #expect(await runtime.sessionHost.telegramChannel(in: window.slotID) == nil)
            #expect(await backend.prompts.isEmpty)
        }
    }

    @Test("While a prompt runs, /telegram and /telegram off run beside it and /telegram on is refused, keeping the draft")
    func whileAPromptRuns() async throws {
        try await withRuntime(telegramConfigured: true) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.commandContext.contains(ZenAppCommands.telegramEnabled) })

            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            #expect(await backend.waitUntilHeld())
            #expect(window.isBusy)

            window.draft = "/telegram on"
            window.submitDraft()
            #expect(window.draft == "/telegram on")
            #expect(window.transcript.last?.content == Self.unavailableWhileRunning)

            window.draft = "/telegram"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            let inactive = ZenWindowSession.withoutTrailingNewlines(
                await runtime.sessionHost.telegramStatusText(in: window.slotID)
            )
            #expect(await eventually {
                window.transcript.contains { $0.content == .local(text: inactive, isFailure: false) }
            })

            window.draft = "/telegram off"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await eventually { window.transcript.contains { $0.content == Self.stopped } })
            #expect(window.isBusy)
            #expect(window.queuedLines.isEmpty)

            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.count == 1)
        }
    }

    // MARK: - Dormant window

    @Test("A dormant window refuses a live mention (keeping the draft), the access-mode switch, attachments (one row), and the sidebar's load and delete")
    func dormantRefusals() async throws {
        try await withRuntime(telegramConfigured: false) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            let mode = runtime.localExecAccessMode
            window.isDrivenFromTelegram = true

            window.draft = "@coordinator status?"
            window.submitDraft()
            #expect(window.draft == "@coordinator status?")
            #expect(window.transcript.last?.content == Self.dormantRefusal)
            window.draft = ""

            window.toggleFullAccess()
            #expect(runtime.localExecAccessMode == mode)
            #expect(window.transcript.last?.content == Self.dormantRefusal)

            let first = workspace.appendingPathComponent("a.txt")
            let second = workspace.appendingPathComponent("b.txt")
            try "a".write(to: first, atomically: true, encoding: .utf8)
            try "b".write(to: second, atomically: true, encoding: .utf8)
            window.attach([first, second])
            #expect(!window.isBusy)
            #expect(window.transcript.last?.content == Self.dormantRefusal)

            window.loadSavedSession(named: "Saved")
            #expect(!window.isBusy)
            #expect(window.loadingSavedSessionName == nil)
            #expect(window.transcript.last?.content == Self.dormantRefusal)

            window.deleteSavedSession(named: "Saved")
            #expect(!window.isBusy)
            #expect(window.transcript.last?.content == Self.dormantRefusal)

            #expect(window.transcript.filter { $0.content == Self.dormantRefusal }.count == 5)
            #expect(await window.waitUntilIdle())
            #expect(await backend.sentSharedChatMessages.isEmpty)
            #expect(await backend.prompts.isEmpty)
            #expect(!window.transcript.contains {
                if case .commandLine = $0.content { return true }
                return false
            })
        }
    }

    @Test("While Telegram drives the slot the queue waits, whole; a line runs at once instead of waiting behind it; /telegram off drains it")
    func dormantQueueWaits() async throws {
        try await withRuntime(telegramConfigured: true) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.commandContext.contains(ZenAppCommands.telegramEnabled) })

            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            #expect(await backend.waitUntilHeld())
            window.draft = "Second"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["Second"])

            // Telegram takes the slot with prompts queued, as after a
            // `/telegram on` the operator typed prompts behind.
            window.isDrivenFromTelegram = true
            await backend.release()
            #expect(await eventually { !window.isBusy })
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.queuedLines.map(\.text) == ["Second"])
            #expect(await backend.prompts.count == 1)

            // A line does not wait behind the queue: it runs now (the host,
            // which the seam left with the window, admits it).
            window.draft = "/help"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["Second"])
            #expect(await eventually { window.transcript.contains { Self.isHelpNotice($0.content) } })
            #expect(await eventually { !window.isBusy })
            #expect(window.queuedLines.map(\.text) == ["Second"])
            #expect(await backend.prompts.count == 1)

            // `/telegram off` takes the slot back: the queue drains.
            window.draft = "/telegram off"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(!window.isDrivenFromTelegram)
            #expect(window.transcript.contains { $0.content == Self.stopped })
            #expect(window.queuedLines.isEmpty)
            let prompts = await backend.prompts
            #expect(prompts.count == 2)
            #expect(prompts.last?.contains("Second") == true)
        }
    }

    // MARK: - Adopted turn

    @Test("A turn adopted from Telegram runs as the window's line: prompts queue, the commands of a running prompt run beside, and the queue drains once its prompt is released")
    func adoptedTurnKeepsPromptsQueued() async throws {
        try await withRuntime(telegramConfigured: true) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.commandContext.contains(ZenAppCommands.telegramEnabled) })
            window.adoptedTelegramTurnSleep = Self.quickSleep

            // The reservation of a turn from Telegram still running when
            // `/telegram off` took the slot back.
            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            window.watchAdoptedTelegramTurn(reservation.promptID)
            #expect(window.adoptedTelegramPromptID == reservation.promptID)

            window.draft = "Queued"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.map(\.text) == ["Queued"])
            #expect(!window.isBusy)

            window.draft = "/models"
            window.submitDraft()
            #expect(window.draft == "/models")
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/models' is unavailable while a prompt is running.",
                isFailure: true
            ))
            window.draft = "/telegram on"
            window.submitDraft()
            #expect(window.transcript.last?.content == Self.unavailableWhileRunning)
            window.draft = "/help"
            window.submitDraft()
            #expect(await eventually { window.transcript.contains { Self.isHelpNotice($0.content) } })

            // Several polls later the turn still runs: the queue waits.
            try await Task.sleep(for: .milliseconds(100))
            #expect(window.queuedLines.map(\.text) == ["Queued"])
            #expect(window.adoptedTelegramPromptID == reservation.promptID)
            #expect(await backend.prompts.isEmpty)

            // The channel releases the turn's prompt.
            await Self.releasePrompt(reservation, in: runtime.sessionHost)
            #expect(await window.waitUntilIdle())
            #expect(window.adoptedTelegramPromptID == nil)
            let prompts = await backend.prompts
            #expect(prompts.count == 1)
            #expect(prompts.last?.contains("Queued") == true)
        }
    }

    @Test("Stop cancels a turn adopted from Telegram: its prompt is dropped and the queue drains")
    func stopEndsTheAdoptedTurn() async throws {
        try await withRuntime(telegramConfigured: false) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            window.adoptedTelegramTurnSleep = Self.quickSleep

            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            window.watchAdoptedTelegramTurn(reservation.promptID)
            window.draft = "After"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["After"])

            window.stop()
            #expect(await window.waitUntilIdle())
            #expect(window.adoptedTelegramPromptID == nil)
            #expect(await backend.prompts.count == 1)
            #expect(await Self.activePromptID(in: runtime.sessionHost, slotID: window.slotID) != reservation.promptID)
        }
    }

    @Test("Closing the window ends the watch of an adopted turn")
    func closeEndsTheAdoptedTurnWatch() async throws {
        try await withRuntime(telegramConfigured: false) { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            window.adoptedTelegramTurnSleep = Self.quickSleep

            let reservation = try await Self.reservePrompt(in: runtime.sessionHost, slotID: window.slotID)
            window.watchAdoptedTelegramTurn(reservation.promptID)
            #expect(window.adoptedTelegramPromptID == reservation.promptID)
            await window.close()
            #expect(window.isClosed)
            #expect(window.adoptedTelegramPromptID == nil)
            #expect(await window.waitUntilIdle())
        }
    }

    @Test("Core texts lose their trailing newlines, and only those")
    func trailingNewlines() {
        #expect(ZenWindowSession.withoutTrailingNewlines("Telegram remote control stopped.\n")
            == "Telegram remote control stopped.")
        #expect(ZenWindowSession.withoutTrailingNewlines("Two\nlines\n\n") == "Two\nlines")
        #expect(ZenWindowSession.withoutTrailingNewlines("\nKept") == "\nKept")
        #expect(ZenWindowSession.withoutTrailingNewlines("") == "")
    }

    // MARK: - Helpers

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

    @ChatSessionActor
    private static func activePromptID(in sessionHost: ChatSessionHost, slotID: ChatSlotID) -> UUID? {
        sessionHost.incarnation(in: slotID)?.activePromptID
    }

    private static func isHelpNotice(_ content: ZenTranscriptItem.Content) -> Bool {
        if case let .notice(notice) = content, case .help = notice {
            return true
        }
        return false
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

    /// Telegram settings that enable it (paired, routing current, one
    /// route), so `/telegram` is visible; nothing here reaches the network.
    private nonisolated static let telegramSettings = AgentTelegramSettingsManifest(
        enabled: true,
        botToken: "123456:zen-app-test-token",
        linkedChatID: 4242,
        linkedChatTitle: "ZenApp tests",
        ownerUserID: 7,
        routingVersion: AgentTelegramSettingsManifest.currentRoutingVersion,
        routes: [AgentTelegramRouteManifest(roomID: "default")]
    )

    /// A runtime over the scripted backend, a hosted configuration, and a
    /// temporary support directory and workspace; the settings enable
    /// Telegram when `telegramConfigured`.
    private func withRuntime(
        telegramConfigured: Bool,
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-telegram-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            if telegramConfigured {
                try AgentSettingsManifestStore.save(
                    AgentSettingsManifest(
                        models: [Self.model],
                        selectedModelID: Self.model.id,
                        telegram: Self.telegramSettings
                    ),
                    to: AgentSettingsManifestStore.settingsURL()
                )
            }
            try await Self.compose(workspace: workspace, body: body)
        }
    }

    private nonisolated static let model = AgentSettingsModelManifest(
        id: "zen-app-model",
        kind: .remoteAPI,
        modelID: "local/zen-app-model"
    )

    private static func compose(
        workspace: URL,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: model.id,
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [model],
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
