//
//  ZenWindowSessionTests+Part1.swift
//  ZenAppSessionTests
//
//  Part 1 of the window session tests over a scripted backend: running lines,
//  streaming, hidden and typed prompts, attachments, stopping a turn, and
//  menus.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

extension ZenWindowSessionTests {
    @Test("A window runs a command and a prompt, queues while busy, refuses commands, and closes on /exit")
    func aWindowRunsLines() async throws {
        try await withRuntime { runtime, backend, workspace in
            #expect(runtime.launchWorkspace == workspace)
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(runtime.windows.count == 1)
            #expect(window.status.workspace == workspace)
            #expect(await eventually { window.snapshot != nil && window.epoch == window.current.epoch })
            #expect(window.commandDescriptors.map(\.command).contains("/exit"))
            #expect(window.sessionTitle == nil)

            // A shared command: the echo, then its notice.
            window.draft = "/help"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.transcript.contains { Self.isHelpNotice($0.content) } })
            let echo = try #require(window.transcript.firstIndex { $0.content == .commandLine("/help") })
            let help = try #require(window.transcript.firstIndex { Self.isHelpNotice($0.content) })
            #expect(echo < help)
            #expect(window.transcript[echo].id.hasPrefix("local-"))

            // A prompt: the prompt and the response, the model in the status bar.
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Hello", isStreaming: false) }
            })
            let prompt = try #require(window.transcript.first {
                $0.content == .userPrompt(text: "Hello", attachments: [], origin: .app)
            })
            #expect(prompt.startsTurn)
            #expect(prompt.id.hasPrefix("\(window.current.epoch)-log-"))
            #expect(window.liveAssistantText.isEmpty)
            #expect(window.liveBlockID == nil)
            #expect(window.liveItems.isEmpty)
            #expect(window.status.modelID == "zen-app-model")
            #expect(window.status.agentName != nil)
            #expect(window.sessionTitle == "Hello")
            #expect(!window.isBusy)
            #expect(window.history.entries == ["/help", "Hello"])

            // While a turn runs: a prompt waits, a command is refused and keeps the draft.
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            #expect(window.isBusy)
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            #expect(window.status.turnStartedAt != nil)
            window.draft = "Second"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["Second"])
            window.draft = "Third"
            window.submitDraft()
            let third = try #require(window.queuedLines.last)
            window.removeQueuedLine(third.id)
            #expect(window.queuedLines.map(\.text) == ["Second"])
            window.draft = "/models"
            window.submitDraft()
            #expect(window.draft == "/models")
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/models' is unavailable while a prompt is running.",
                isFailure: true
            ))
            // /exit waits for the prompt to end, as in the terminal.
            window.draft = "/exit"
            window.submitDraft()
            #expect(window.draft == "/exit")
            #expect(!window.closeRequested)
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/exit' is unavailable while a prompt is running.",
                isFailure: true
            ))
            window.draft = ""
            window.startNewSession()
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: command '/sessions' is unavailable while a prompt is running.",
                isFailure: true
            ))
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(window.queuedLines.isEmpty)
            let prompts = await backend.prompts
            #expect(prompts.count == 3)
            #expect(prompts.last?.contains("Second") == true)
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Second", isStreaming: false) }
            })

            // History navigation into the draft.
            #expect(window.recallPreviousPrompt())
            #expect(window.draft == "/exit")
            #expect(window.recallPreviousPrompt())
            #expect(window.draft == "/models")
            #expect(window.recallNextPrompt())
            #expect(window.draft == "/exit")
            #expect(window.recallNextPrompt())
            #expect(window.draft == "")
            #expect(!window.recallNextPrompt())

            // /exit asks the window to close.
            window.draft = "/exit"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(window.closeRequested)

            await window.close()
            #expect(window.isClosed)
            #expect(runtime.windows.isEmpty)
            await runtime.shutdown()
            #expect(runtime.isShutDown)
            #expect(await runtime.sessionHost.isShutDown)
        }
    }

    @Test("Streaming publishes the live block on its own; the transcript and the snapshot are not touched by a token")
    func streamingDoesNotTouchTheTranscript() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            await backend.hold()
            window.draft = "Stream"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually {
                window.transcript.contains { $0.content == .userPrompt(text: "Stream", attachments: [], origin: .app) }
            })
            let transcriptChanges = ZenObservationCounter { _ = window.transcript }
            let snapshotChanges = ZenObservationCounter { _ = window.snapshot }
            let liveChanges = ZenObservationCounter { _ = window.liveAssistantText }
            let transcript = window.transcript

            // Tokens of the turn, as the controller presents them.
            let reducer = try #require(window.current.reducer)
            for token in ["One ", "two ", "three"] {
                await reducer.presentAssistantContent(token)
                #expect(await eventually { window.liveAssistantText.hasSuffix(token) })
            }
            #expect(window.liveAssistantText == "One two three")
            #expect(await eventually { liveChanges.count >= 1 })
            #expect(window.transcript == transcript)
            #expect(transcriptChanges.count == 0)
            #expect(snapshotChanges.count == 0)

            // The block closes into the transcript when the turn ends.
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains {
                    $0.content == .assistantText("One two threeScripted answer to Stream", isStreaming: false)
                }
            })
            #expect(await eventually { transcriptChanges.count >= 1 })
            #expect(snapshotChanges.count == 0)
            #expect(window.liveThought.isEmpty)
            #expect(window.liveAssistantText.isEmpty)
            #expect(window.liveTurnID == nil)
            #expect(window.liveBlockID == nil)
            await runtime.shutdown()
        }
    }

    @Test("The live block has its own id per block and session")
    func liveBlockIDs() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            await backend.hold()
            window.draft = "Live"
            window.submitDraft()
            await backend.waitUntilHeld()
            // The scripted answer streams after the release: present the
            // block on the reducer meanwhile, as the controller does.
            let reducer = try #require(window.current.reducer)
            await reducer.presentThought("Reasoning")
            await reducer.presentAssistantContent("Writing")
            #expect(await eventually { window.liveAssistantText == "Writing" })
            #expect(window.liveThought == "Reasoning")
            let blockID = try #require(window.liveBlockID)
            #expect(blockID.hasPrefix("\(window.current.epoch)-live-"))
            #expect(window.liveTurnID != nil)
            #expect(window.liveItems.map(\.id) == ["\(blockID)-thought", "\(blockID)-assistant"])
            #expect(window.liveItems.map(\.content) == [
                .thought("Reasoning", isStreaming: true),
                .assistantText("Writing", isStreaming: true),
            ])
            #expect(!window.transcript.contains { $0.id.contains("-live-") })
            // A tool call closes the block; the next block has another id.
            await reducer.presentToolCallStarted(
                DirectAgentToolCall(id: "c1", name: "local.read", argumentsObject: [:], argumentsJSON: "{}")
            )
            #expect(await eventually { window.liveBlockID == nil })
            await reducer.presentAssistantContent("More")
            #expect(await eventually { window.liveBlockID != nil })
            #expect(window.liveBlockID != blockID)
            await backend.release()
            #expect(await window.waitUntilIdle())
            await runtime.shutdown()
        }
    }

    @Test("Row ids are unique across the sessions of a window")
    func idsAreUniqueAcrossSessions() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.sessionTitle == "Hello" })
            let firstEpoch = window.current.epoch
            let firstIDs = Set(window.transcript.map(\.id))

            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch != firstEpoch && window.epoch == window.current.epoch })
            #expect(await eventually { window.sessionTitle == nil })
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Hello", isStreaming: false) }
            })
            let secondIDs = window.transcript.map(\.id)
            #expect(Set(secondIDs).count == secondIDs.count)
            #expect(firstIDs.isDisjoint(with: secondIDs))
            await runtime.shutdown()
        }
    }

    @Test("A prompt a command built is hidden: no row, no title, no separator; the typed prompt shows")
    func commandBuiltPromptsAreHidden() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            window.draft = "/plan Build a parser"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let prompts = await backend.prompts
            try #require(prompts.count == 1, "the /plan turn ran: \(window.transcript.map(\.content))")
            #expect(prompts[0].contains("Build a parser"))
            // The log has the prompt of the /plan turn; the transcript does not.
            #expect(await eventually {
                window.snapshot?.log.contains {
                    if case let .userPrompt(text, _, _) = $0.kind { return text == prompts[0] }
                    return false
                } == true
            })
            #expect(window.transcript.contains { $0.content == .commandLine("/plan Build a parser") })
            #expect(!window.transcript.contains {
                if case .userPrompt = $0.content { return true }
                return false
            })
            #expect(!window.transcript.contains { $0.startsTurn })
            #expect(window.sessionTitle == nil)
            // The Core derives its title from the hidden prompt; the window does not.
            #expect(window.snapshot?.summary.title != nil)

            window.draft = "Typed by me"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.sessionTitle == "Typed by me" })
            let visible = window.transcript.filter(\.startsTurn)
            #expect(visible.map(\.content) == [.userPrompt(text: "Typed by me", attachments: [], origin: .app)])
            await runtime.shutdown()
        }
    }

    @Test("A reply the operator types shows as their prompt; the prompt it builds stays hidden")
    func typedRepliesShowAsPrompts() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let orchestrator = await runtime.runner.taskOrchestrator
            let sessionID = window.current.sessionID

            // A /goal workflow asks the operator a question while its turn runs.
            await backend.hold()
            window.draft = "/goal Ship the parser"
            window.submitDraft()
            await backend.waitUntilHeld()
            let graphs = try await orchestrator.graphSnapshots(sessionID: sessionID)
            let graph = try #require(graphs.first { $0.source == .workflow })
            try await orchestrator.updateWorkflow(
                sessionID: sessionID,
                graphID: graph.id,
                state: .awaitingUser,
                message: "Which language?",
                expectedRevision: graph.revision
            )
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains {
                    if case .workflowNotice(.awaitingReply) = $0.content { return true }
                    return false
                }
            })
            let promptCount = await backend.prompts.count

            let noticeIndex = try #require(window.transcript.lastIndex {
                if case .workflowNotice(.awaitingReply) = $0.content { return true }
                return false
            })

            // The reply's turn is held: the workflow would go on by itself.
            await backend.hold()
            window.draft = "Use Swift"
            window.submitDraft()
            await backend.waitUntilHeld()
            let prompts = await backend.prompts
            try #require(prompts.count > promptCount, "\(window.transcript.map(\.content))")
            // The model receives the prompt the reply built, not the line.
            let continuation = prompts[promptCount]
            #expect(continuation != "Use Swift")
            #expect(await eventually {
                window.snapshot?.log.contains {
                    if case let .userPrompt(text, _, _) = $0.kind { return text == continuation }
                    return false
                } == true
            })
            let echoIndex = try #require(window.transcript.firstIndex {
                $0.content == .userPrompt(text: "Use Swift", attachments: [], origin: .app)
            })
            #expect(echoIndex > noticeIndex)
            #expect(window.transcript[echoIndex].id.hasPrefix("local-"))
            #expect(window.transcript[echoIndex].startsTurn)
            #expect(!window.transcript.contains {
                if case let .userPrompt(text, _, _) = $0.content { return text == continuation }
                return false
            })
            #expect(window.transcript.filter { $0.startsTurn }.map(\.content) == [
                .userPrompt(text: "Hello", attachments: [], origin: .app),
                .userPrompt(text: "Use Swift", attachments: [], origin: .app),
            ])
            window.stop()
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(window.sessionTitle == "Hello")
            await runtime.shutdown()
        }
    }

    @Test("Staged attachments go to the next typed prompt, not to a turn a command built")
    func attachmentsGoToTypedPrompts() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let file = workspace.appendingPathComponent("pixel.png")
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(to: file)
            window.attach([file])
            #expect(await window.waitUntilIdle())
            #expect(!window.transcript.contains {
                if case .notice(.operationFailed) = $0.content { return true }
                return false
            })

            window.draft = "/plan Build a parser"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            window.draft = "With the file"
            window.submitDraft()
            #expect(await window.waitUntilIdle())

            let prompts = await backend.prompts
            let attachments = await backend.attachments
            try #require(prompts.count == 2, "\(window.transcript.map(\.content))")
            #expect(attachments[0].isEmpty)
            #expect(attachments[1].count == 1)
            #expect(window.transcript.contains {
                if case let .userPrompt(text, promptAttachments, _) = $0.content {
                    return text == "With the file" && promptAttachments.count == 1
                }
                return false
            })
            await runtime.shutdown()
        }
    }

    @Test("Stop cancels the running turn and keeps the queue")
    func stopCancelsTheTurn() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            window.draft = "After"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["After"])
            window.stop()
            #expect(await eventually {
                window.transcript.contains { $0.content == .local(text: "Turn cancelled.", isFailure: false) }
            })
            await backend.release()
            #expect(await window.waitUntilIdle())
            // The queued prompt ran after the cancel.
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to After", isStreaming: false) }
            })
            await runtime.shutdown()
            #expect(window.isClosed)
        }
    }

    @Test("A stop between the reservation and the turn leaves the turn unstarted")
    func stopBeforeTheTurnStarts() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let gate = ZenGate()
            window.turnDidReserve = { await gate.pass() }
            window.draft = "Gated"
            window.submitDraft()
            await waitUntil("the turn reserved its prompt") { await gate.reached }
            #expect(await runtime.sessionHost.incarnation(in: window.slotID)?.activePromptID != nil)
            window.stop()
            await waitUntil("the stop dropped the reservation") {
                await runtime.sessionHost.incarnation(in: window.slotID)?.activePromptID == nil
            }
            await gate.open()
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.last?.content == .local(text: "Turn cancelled.", isFailure: false))
            #expect(await backend.prompts.isEmpty)
            #expect(!window.transcript.contains {
                $0.content == .userPrompt(text: "Gated", attachments: [], origin: .app)
            })

            // The next prompt reserves and runs normally.
            window.turnDidReserve = nil
            window.draft = "Next"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Next", isStreaming: false) }
            })
            #expect(await backend.prompts == ["Next"])
            await runtime.shutdown()
        }
    }

    @Test("A stop right after a submit, before the prompt is reserved, keeps the turn from starting")
    func stopRightAfterSubmit() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Quick"
            window.submitDraft()
            // Before anything suspends: the line has not run, so its prompt is
            // not reserved yet.
            window.stop()
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.contains { $0.content == .local(text: "Turn cancelled.", isFailure: false) })
            #expect(!window.transcript.contains {
                $0.content == .userPrompt(text: "Quick", attachments: [], origin: .app)
            })
            #expect(await backend.prompts.isEmpty)
            #expect(await runtime.sessionHost.incarnation(in: window.slotID)?.activePromptID == nil)
            // The stop belonged to that line: the next prompt runs.
            window.draft = "Then"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Then", isStreaming: false) }
            })
            #expect(await backend.prompts == ["Then"])
            await runtime.shutdown()
        }
    }

    @Test("Stop while a command waits on a menu refuses the request, ends the line, and keeps the queue")
    func stopWhileAMenuIsOpen() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "/models"
            window.submitDraft()
            #expect(await eventually {
                if case .chooseOne? = window.pendingRequest?.kind { return true }
                return false
            })
            #expect(window.isBusy)
            window.draft = "After"
            window.submitDraft()
            #expect(window.queuedLines.map(\.text) == ["After"])

            window.stop()
            #expect(await eventually { window.pendingRequest == nil })
            // The menu's line ended, then the queued prompt ran: the queue
            // was kept.
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to After", isStreaming: false) }
            })
            #expect(await window.waitUntilIdle())
            #expect(window.queuedLines.isEmpty)
            #expect(await backend.prompts == ["After"])
            await runtime.shutdown()
        }
    }

    @Test("A menu opens over the anchor its line was launched from, and a typed line's over the composer")
    func menuAnchorOfALaunchedLine() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            let anchor = ZenMenuAnchor(id: "/models")
            window.run("/models", menuAnchor: anchor)
            #expect(await eventually {
                if case .chooseOne? = window.pendingRequest?.kind { return true }
                return false
            })
            #expect(window.pendingRequestAnchor == anchor)

            let launched = try #require(window.pendingRequest)
            window.answer(launched.id, with: nil)
            #expect(await eventually { window.pendingRequest == nil })
            #expect(window.pendingRequestAnchor == nil)
            #expect(await window.waitUntilIdle())

            // A typed line: its menu opens over the composer.
            window.draft = "/models"
            window.submitDraft()
            #expect(await eventually {
                if case .chooseOne? = window.pendingRequest?.kind { return true }
                return false
            })
            #expect(window.pendingRequestAnchor == nil)

            let typed = try #require(window.pendingRequest)
            window.answer(typed.id, with: nil)
            #expect(await eventually { window.pendingRequest == nil })
            #expect(await window.waitUntilIdle())
            await runtime.shutdown()
        }
    }

    private static func isHelpNotice(_ content: ZenTranscriptItem.Content) -> Bool {
        if case let .notice(notice) = content, case .help = notice {
            return true
        }
        return false
    }
}
