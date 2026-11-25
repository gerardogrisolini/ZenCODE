//
//  ZenWindowSessionTests.swift
//  ZenAppSessionTests
//
//  The composition of the app over a scripted backend: a runtime, a window,
//  commands, prompts, the queue, a cancel, the sub-agent overview, hidden
//  prompts, the task graph, the artifacts sidebar, the sub-agent tabs, and the
//  close.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenWindowSessionTests {
    @Test("session and attachment controls are available only when their operations are admitted")
    func controlAvailability() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(window.canManageSessions)
            #expect(window.canAttachFiles)

            window.isBusy = true
            #expect(!window.canManageSessions)
            #expect(!window.canAttachFiles)
            window.isBusy = false
            window.queuedLines = [ZenQueuedLine(text: "next")]
            #expect(!window.canManageSessions)
            window.queuedLines = []
            window.adoptedTelegramPromptID = UUID()
            #expect(!window.canManageSessions)
            #expect(!window.canAttachFiles)
            window.adoptedTelegramPromptID = nil
            window.isDrivenFromTelegram = true
            #expect(!window.canManageSessions)
            #expect(!window.canAttachFiles)
            window.isDrivenFromTelegram = false
            #expect(window.canManageSessions)
            #expect(window.canAttachFiles)
            await runtime.shutdown()
        }
    }

    @Test("Sub-agent tabs open only when asked, once each, follow their agent, and close to the adjacent tab")
    func subAgentTabsOpenSelectAndClose() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            // A turn gives the session the backend the tabs read.
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let root = window.current.sessionID
            await backend.setSubAgents(["agent-1", "agent-2", "agent-3"].map { Self.subAgent($0, root: root) })
            await backend.setSubAgentTranscript(ChatSubAgentTranscript(
                agentID: "agent-1",
                kinds: [
                    .userPrompt(text: "Brief", attachments: [], origin: .unknown),
                    .assistantText("Working on it."),
                ]
            ))
            // Nothing opens a tab by itself.
            #expect(window.tabs == [.chat])
            #expect(window.selectedTab == .chat)
            #expect(window.subAgentTabs.isEmpty)

            window.openSubAgentTab("agent-1")
            #expect(window.tabs == [.chat, .subAgent("agent-1")])
            #expect(window.selectedTab == .subAgent("agent-1"))
            let first = try #require(window.subAgentTab("agent-1"))
            // The tab follows its agent: its snapshot and its transcript.
            #expect(await eventually {
                first.snapshot?.name == "Worker agent-1" && first.items.count == 2
            })
            #expect(first.items.map(\.id) == ["subagent-agent-1-0", "subagent-agent-1-1"])
            #expect(first.availability == .available)
            #expect(await backend.snapshotObserverCount == 1)

            // Opening an open tab selects it and adds nothing.
            window.selectTab(.chat)
            #expect(window.selectedTab == .chat)
            window.openSubAgentTab("agent-1")
            #expect(window.subAgentTabs.count == 1)
            #expect(window.subAgentTab("agent-1") === first)
            #expect(window.selectedTab == .subAgent("agent-1"))

            window.openSubAgentTab("agent-2")
            window.openSubAgentTab("agent-3")
            #expect(window.tabs == [.chat, .subAgent("agent-1"), .subAgent("agent-2"), .subAgent("agent-3")])
            #expect(window.selectedTab == .subAgent("agent-3"))
            // A tab that is not open cannot be selected.
            window.selectTab(.subAgent("agent-9"))
            #expect(window.selectedTab == .subAgent("agent-3"))
            // An agent without a transcript says so.
            let second = try #require(window.subAgentTab("agent-2"))
            #expect(await eventually { second.availability == .unavailable })

            // Closing a tab that is not selected keeps the selection.
            window.closeSubAgentTab("agent-2")
            #expect(window.tabs == [.chat, .subAgent("agent-1"), .subAgent("agent-3")])
            #expect(window.selectedTab == .subAgent("agent-3"))
            #expect(second.isStopped)
            // Closing the selected tab selects the tab after it, else the one before.
            window.selectTab(.subAgent("agent-1"))
            window.closeSubAgentTab("agent-1")
            #expect(window.selectedTab == .subAgent("agent-3"))
            #expect(first.isStopped)
            window.closeSubAgentTab("agent-3")
            #expect(window.selectedTab == .chat)
            #expect(window.tabs == [.chat])
            // Every model released its stream.
            #expect(await waitUntil("the streams are released") { await backend.snapshotObserverCount == 0 })
            await runtime.shutdown()
        }
    }

    @Test("A new or loaded session closes the sub-agent tabs and shows the conversation; closing the window stops them")
    func subAgentTabsCloseWithTheSession() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await backend.setSubAgents([Self.subAgent("agent-1", root: window.current.sessionID)])
            window.saveSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.currentSavedSessionName != nil })
            let name = try #require(window.currentSavedSessionName)

            // A new session.
            window.openSubAgentTab("agent-1")
            let beforeNew = try #require(window.subAgentTab("agent-1"))
            let firstEpoch = window.current.epoch
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch })
            #expect(window.subAgentTabs.isEmpty)
            #expect(window.selectedTab == .chat)
            #expect(beforeNew.isStopped)

            // A loaded session.
            window.openSubAgentTab("agent-1")
            let beforeLoad = try #require(window.subAgentTab("agent-1"))
            #expect(window.selectedTab == .subAgent("agent-1"))
            let secondEpoch = window.current.epoch
            window.loadSavedSession(named: name)
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != secondEpoch })
            #expect(window.subAgentTabs.isEmpty)
            #expect(window.selectedTab == .chat)
            #expect(beforeLoad.isStopped)

            // Closing the window stops the tabs it has, and opens no other.
            window.openSubAgentTab("agent-1")
            let beforeClose = try #require(window.subAgentTab("agent-1"))
            await window.close()
            #expect(beforeClose.isStopped)
            window.openSubAgentTab("agent-2")
            #expect(window.subAgentTab("agent-2") == nil)
            await runtime.shutdown()
        }
    }

    @Test("Each tab model knows whether its tab is the selected one, from the opening on")
    func subAgentTabsKnowTheirSelection() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let root = window.current.sessionID
            await backend.setSubAgents(["agent-1", "agent-2"].map { Self.subAgent($0, root: root) })

            window.openSubAgentTab("agent-1")
            let first = try #require(window.subAgentTab("agent-1"))
            #expect(first.isSelected)
            window.openSubAgentTab("agent-2")
            let second = try #require(window.subAgentTab("agent-2"))
            #expect(!first.isSelected)
            #expect(second.isSelected)
            window.selectTab(.chat)
            #expect(!first.isSelected)
            #expect(!second.isSelected)
            window.selectTab(.subAgent("agent-1"))
            #expect(first.isSelected)
            #expect(!second.isSelected)
            // Closing the selected tab selects the next one, and says so.
            window.closeSubAgentTab("agent-1")
            #expect(window.selectedTab == .subAgent("agent-2"))
            #expect(second.isSelected)
            window.closeSubAgentTab("agent-2")
            #expect(window.selectedTab == .chat)
            await runtime.shutdown()
        }
    }

    @Test("A tab opened with the overview's snapshot reads the transcript once: the stream's first value repeats it")
    func subAgentTabReadsOnceWhenItOpens() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let call = DirectAgentToolCall(id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}")
            await backend.script(prompt: "Delegate", events: [
                .toolCallStarted(call),
                .toolCallCompleted(call, DirectAgentToolResult(output: "created", summary: "created")),
            ])
            await backend.setSubAgents([Self.subAgent("agent-1", root: window.current.sessionID)])
            await backend.setSubAgentTranscript(ChatSubAgentTranscript(
                agentID: "agent-1",
                kinds: [.userPrompt(text: "Brief", attachments: [], origin: .unknown)]
            ))
            window.draft = "Delegate"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.subAgents.snapshots.map(\.id) == ["agent-1"] })

            window.openSubAgentTab("agent-1")
            let model = try #require(window.subAgentTab("agent-1"))
            #expect(await eventually { model.updateCount >= 1 && model.items.count == 1 })
            try? await Task.sleep(for: .milliseconds(80))
            #expect(await backend.subAgentTranscriptReadCount == 1)
            #expect(model.transcriptReadCount == 1)
            await runtime.shutdown()
        }
    }

    @Test("The commands the operator launches select the conversation first; stop leaves the tab as it is")
    func commandsSelectTheConversation() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await backend.setSubAgents([Self.subAgent("agent-1", root: window.current.sessionID)])

            // A menu or toolbar command.
            window.openSubAgentTab("agent-1")
            window.run("/help")
            #expect(window.selectedTab == .chat)
            #expect(await window.waitUntilIdle())

            // The session operations that write in the conversation.
            window.selectTab(.subAgent("agent-1"))
            window.saveSession()
            #expect(window.selectedTab == .chat)
            #expect(await window.waitUntilIdle())

            window.selectTab(.subAgent("agent-1"))
            window.loadSavedSession(named: "missing-session")
            #expect(window.selectedTab == .chat)
            #expect(await window.waitUntilIdle())

            window.selectTab(.subAgent("agent-1"))
            window.deleteSavedSession(named: "missing-session")
            #expect(window.selectedTab == .chat)
            #expect(await window.waitUntilIdle())

            // ⌘. stops from any tab, where it is.
            window.selectTab(.subAgent("agent-1"))
            window.stop()
            #expect(window.selectedTab == .subAgent("agent-1"))

            window.startNewSession()
            #expect(window.selectedTab == .chat)
            #expect(await window.waitUntilIdle())
            await runtime.shutdown()
        }
    }

    @Test("A new session is a new incarnation: the transcript starts over")
    func newSessionReplacesTheIncarnation() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let firstEpoch = window.current.epoch
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.sessionTitle == "Hello" })

            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch && window.snapshot?.epoch == window.current.epoch })
            #expect(await eventually { window.transcript.contains { $0.content == .notice(.sessionStarted) } })
            #expect(!window.transcript.contains {
                $0.content == .userPrompt(text: "Hello", attachments: [], origin: .app)
            })
            #expect(window.current.sessionID.hasPrefix("\(ChatSlotDescriptor.defaultSessionIDPrefix)-"))
            await runtime.shutdown()
        }
    }

    @Test("A new session keeps the agent, tools, and skills the operator chose in the session it replaces")
    func newSessionKeepsTheSelection() async throws {
        try await withRuntime { runtime, _, workspace in
            // An installed skill, in the temporary support directory.
            let skill = AppStorageDirectory.appSupportDirectoryURL()
                .appendingPathComponent("skills/kept-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try """
            ---
            name: kept-skill
            description: The kept-skill test skill.
            ---

            # kept-skill
            """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil && window.epoch == window.current.epoch })
            for line in ["/agents tester", "/tools shell", "/skills kept-skill"] {
                window.draft = line
                window.submitDraft()
                #expect(await window.waitUntilIdle())
            }
            #expect(await eventually {
                window.snapshot?.selection.agent?.id == "tester"
                    && window.snapshot?.selection.toolKeys == ["shell"]
                    && window.snapshot?.selection.skillNames == ["kept-skill"]
            })
            let kept = try #require(window.snapshot?.selection)

            let firstEpoch = window.current.epoch
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch && window.snapshot?.epoch == window.current.epoch })
            #expect(await eventually { window.transcript.contains { $0.content == .notice(.sessionStarted) } })
            #expect(window.snapshot?.selection == kept)
            await runtime.shutdown()
        }
    }

    @Test("The first window creates its session, preloads the model, and discovers backend tools before the first prompt")
    func firstWindowStartsLikeTheTerminal() async throws {
        try await withRuntime { runtime, backend, workspace in
            let xcode = DirectToolDescriptor(
                name: "xcode.build",
                description: "Builds an Xcode project.",
                inputSchema: #"{"type":"object"}"#
            )
            await backend.setToolDescriptors([xcode])

            let window = try await runtime.openWindow(workspace: workspace)
            let sessionID = await window.current.controller.sessionID
            let initialCreations = await backend.createdSessionIDs
            #expect(initialCreations == [sessionID])
            #expect(await backend.preloadCount == 1)
            #expect(await backend.toolDescriptorReadCount > 0)
            #expect(window.startupSummary?.activeTools == (await window.current.controller.activeToolsSummary()))
            #expect(window.status.modelID == "local/zen-app-model")

            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts == ["Hello"])
            // The prompt refreshes dynamic context and locks the response
            // language, but it must keep the same runtime session and model.
            #expect(Set(await backend.createdSessionIDs) == [sessionID])
            #expect(await backend.preloadCount == 1)
            await runtime.shutdown()
        }
    }

    @Test("The welcome view's startup summary is read with the status bar and follows the agent, tools, and skills")
    func startupSummaryFollowsTheSelection() async throws {
        try await withRuntime { runtime, _, workspace in
            // An installed skill, in the temporary support directory.
            let skill = AppStorageDirectory.appSupportDirectoryURL()
                .appendingPathComponent("skills/summary-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try """
            ---
            name: summary-skill
            description: The summary-skill test skill.
            ---

            # summary-skill
            """.write(to: skill.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

            let window = try await runtime.openWindow(workspace: workspace)
            // Read when the window opens, from the controller the slot runs.
            let controller = window.current.controller
            let opened = try #require(window.startupSummary)
            #expect(opened.agentName != nil)
            #expect(opened.agentName == (await controller.selection.agent?.displayName))
            #expect(opened.activeTools == (await controller.activeToolsSummary()))
            #expect(opened.activeSkills == (await controller.selectedPromptSkills()))

            for line in ["/agents tester", "/tools shell", "/skills summary-skill"] {
                window.draft = line
                window.submitDraft()
                #expect(await window.waitUntilIdle())
            }
            let tester = AgentProfileStore.defaultProfiles().first { $0.id == "tester" }?.displayName
            #expect(tester != nil)
            #expect(await eventually {
                window.startupSummary?.agentName == tester
                    && window.startupSummary?.activeTools.groups.first?.title == "Shell"
                    && window.startupSummary?.activeSkills.map(\.canonicalName) == ["summary-skill"]
            })
            #expect(window.startupSummary?.activeTools == (await controller.activeToolsSummary()))
            await runtime.shutdown()
        }
    }

    @Test("Save, load, and delete a saved session; the response language locks per incarnation")
    func savedSessionsAndResponseLanguage() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await Self.fixLanguage(of: window.hooks, to: "Italian")
            #expect(await window.hooks.isResponseLanguageLocked == false)
            #expect(await window.hooks.responseLanguageSection() == nil)

            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            // The first prompt the operator typed locks the language.
            #expect(await window.hooks.isResponseLanguageLocked)
            #expect(await window.hooks.responseLanguageSection()
                == SystemPromptBuilder.responseLanguageSection(languageName: "Italian"))
            #expect(await backend.systemPrompts.contains { $0.contains("Italian") })

            window.saveSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.currentSavedSessionName != nil })
            let name = try #require(window.currentSavedSessionName)
            #expect(await eventually { window.savedSessions.map(\.name) == [name] })
            #expect(await eventually { window.sessionTitle == name })
            #expect(window.transcript.contains {
                if case let .notice(notice) = $0.content, case .sessionSaved = notice { return true }
                return false
            })

            // A new session starts unlocked, with an empty transcript.
            let firstEpoch = window.current.epoch
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch })
            #expect(await window.hooks.isResponseLanguageLocked == false)

            // Loading the saved session restores its transcript in a new incarnation.
            let secondEpoch = window.current.epoch
            window.loadSavedSession(named: name)
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != secondEpoch && window.snapshot?.epoch == window.current.epoch })
            #expect(await eventually {
                window.transcript.contains { $0.content == .userPrompt(text: "Hello", attachments: [], origin: .unknown) }
            })
            #expect(await eventually { window.currentSavedSessionName == name })

            // A missing session answers with a local failure.
            window.loadSavedSession(named: "missing-session")
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.last?.content == .local(
                    text: "ZenCODE: saved session 'missing-session' not found.",
                    isFailure: true
                )
            })

            // The delete runs on the session the slot runs now.
            window.deleteSavedSession(named: name)
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.savedSessions.isEmpty })
            #expect(window.transcript.contains {
                if case let .notice(notice) = $0.content, case .sessionDeleted = notice { return true }
                return false
            })
            await runtime.shutdown()
        }
    }

    @Test("Shutdown fences every window before it cancels their work, closes them at once, and runs once")
    func shutdownClosesEveryWindow() async throws {
        try await withRuntime { runtime, backend, workspace in
            let first = try await runtime.openWindow(workspace: workspace)
            let second = try await runtime.openWindow(workspace: workspace)
            await backend.hold()
            first.draft = "Long"
            first.submitDraft()
            await backend.waitUntilHeld()
            first.draft = "Queued"
            first.submitDraft()
            let transcript = first.transcript

            await runtime.shutdown()
            // Each window's runner shut its backend down, fencing the turns,
            // before the window's line, and its held turn, was cancelled.
            let events = backend.lifecycle.events
            #expect(events.filter { $0 == .backendShutDown }.count == 2)
            #expect(events.filter { $0 == .heldTurnCancelled }.count == 1)
            #expect(events.last == .heldTurnCancelled)
            #expect(first.isClosed)
            #expect(second.isClosed)
            #expect(!first.isBusy)
            #expect(first.queuedLines.isEmpty)
            #expect(await first.waitUntilIdle())
            #expect(runtime.windows.isEmpty)
            #expect(await runtime.sessionHost.isShutDown)
            await backend.release()
            await waitUntil("the held turn ended") { await !backend.isHolding }
            try await Task.sleep(for: .milliseconds(100))
            #expect(first.transcript == transcript)
            #expect(await backend.prompts == ["Long"])
            await runtime.shutdown()
            await #expect(throws: ChatSessionHostError.shutDown) {
                _ = try await runtime.openWindow(workspace: workspace)
            }
        }
    }

    // MARK: - Helpers

    /// Sets the language a lock decides, so the test does not depend on the
    /// machine's language.
    @ChatSessionActor
    private static func fixLanguage(of hooks: ZenWindowHooks, to name: String) {
        hooks.languageNameResolver = { name }
    }

    /// A running sub-agent of the root session `root`.
    private static func subAgent(_ id: String, root: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            rootSessionID: root,
            name: "Worker \(id)",
            status: .running,
            pending: true,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    /// Polls `condition` on the main actor until it holds or 10 s pass.
    func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A runtime over the scripted backend, a hosted configuration, and a
    /// temporary support directory and workspace.
    func withRuntime(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        try await withRuntime(models: Self.defaultModels, body)
    }

    /// The hosted model of the ordinary fixture.
    static let defaultModels = [
        AgentSettingsModelManifest(
            id: "zen-app-model",
            kind: .remoteAPI,
            modelID: "local/zen-app-model"
        ),
    ]

    /// ``withRuntime(_:)`` with the hosted `models`, the first one the launch
    /// model.
    func withRuntime(
        models: [AgentSettingsModelManifest],
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-session-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await Self.compose(workspace: workspace, models: models, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        models: [AgentSettingsModelManifest],
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: models[0].id,
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: models,
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
