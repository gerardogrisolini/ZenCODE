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
                DirectAgentToolCall(id: "c1", name: "local.readFile", argumentsObject: [:], argumentsJSON: "{}")
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

    @Test("Closing during a turn fences it: the slot ends, and the window writes nothing after")
    func closeDuringATurn() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            window.draft = "Queued"
            window.submitDraft()
            #expect(await eventually {
                window.transcript.contains { $0.content == .userPrompt(text: "Long", attachments: [], origin: .app) }
            })
            let transcript = window.transcript
            let status = window.status

            await window.close()
            #expect(window.isClosed)
            #expect(!window.isBusy)
            #expect(window.queuedLines.isEmpty)
            #expect(runtime.windows.isEmpty)
            // The slot is gone with its reservation.
            #expect(await runtime.sessionHost.incarnation(in: window.slotID) == nil)
            await backend.release()
            await waitUntil("the held turn ended") { await !backend.isHolding }
            try await Task.sleep(for: .milliseconds(200))
            #expect(window.transcript == transcript)
            #expect(window.status.modelID == status.modelID)
            #expect(window.liveAssistantText.isEmpty)
            #expect(await backend.prompts == ["Long"])
            // A second close does nothing.
            await window.close()
            await runtime.shutdown()
        }
    }

    @Test("The queue holds 32 prompts; one more is refused with the terminal's message and keeps the draft")
    func queueIsBounded() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(ZenWindowSession.queueCapacity == 32)
            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            for index in 1...ZenWindowSession.queueCapacity {
                window.draft = "Queued \(index)"
                window.submitDraft()
            }
            #expect(window.queuedLines.count == 32)
            window.draft = "One too many"
            window.submitDraft()
            #expect(window.draft == "One too many")
            #expect(window.queuedLines.count == 32)
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE: prompt queue is full; wait for the current prompt to finish.",
                isFailure: true
            ))
            for line in window.queuedLines {
                window.removeQueuedLine(line.id)
            }
            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts == ["Busy"])
            await runtime.shutdown()
        }
    }

    @Test("The status facts are read at start and after selections and sessions, not after every line")
    func statusFactsAreReadWhenNeeded() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            #expect(window.status.modelID == "zen-app-model")
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            let reads = window.statusFactsReadCount
            #expect(reads >= 1)

            for line in ["Again", "/help", "/tasks"] {
                window.draft = line
                window.submitDraft()
                #expect(await window.waitUntilIdle())
            }
            #expect(window.statusFactsReadCount == reads)

            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            #expect(await window.waitUntilIdle())
            #expect(window.statusFactsReadCount > reads)
            #expect(window.status.modelID == "zen-app-model")
            await runtime.shutdown()
        }
    }

    @Test("A turn's task card follows the significant changes while the turn generates, then stays; a later turn adds its own; a new session shows none")
    func taskCardOfATurn() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await runtime.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            // A significant change while the turn generates: one card, after
            // the turn's prompt.
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            _ = try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(title: "A"), TaskDefinition(title: "B")]
            )
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 1 })
            let card = try #require(Self.taskCards(in: window.transcript).first)
            #expect(card.id.hasPrefix("local-"))
            #expect(Self.taskCount(card) == 2)
            let firstPrompt = try #require(window.transcript.firstIndex {
                $0.content == .userPrompt(text: "First", attachments: [], origin: .app)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > firstPrompt)

            // A row arrives, then a second change: the same card, moved after
            // the row, with the graph as it is now.
            let marker = ChatSessionNotice.help(commandHelp: ["Card marker"])
            await Self.present(marker, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(marker) } })
            let markerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < markerIndex)
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "C")])
            #expect(await eventually { Self.taskCards(in: window.transcript).first.flatMap(Self.taskCount) == 3 })
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            let movedMarkerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > movedMarkerIndex)
            #expect(window.transcript.last?.id == card.id)
            await backend.release()
            #expect(await window.waitUntilIdle())
            // The answer streamed after the card, which stays where it was.
            let answer = try #require(window.transcript.firstIndex {
                $0.content == .assistantText("Scripted answer to First", isStreaming: false)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < answer)

            // A change once the turn ended shows nothing.
            let settled = window.transcript
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "D")])
            #expect(await eventually { window.snapshot?.taskGraph?.graph.tasks.count == 4 })
            #expect(window.transcript == settled)

            // The next turn: no card until a change, then a card of its own;
            // the first one stays where it is, as it was.
            await backend.hold()
            window.draft = "Second"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "E")])
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 2 })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.first?.id == card.id)
            #expect(cards.first.flatMap(Self.taskCount) == 3)
            #expect(cards.last?.id != card.id)
            #expect(cards.last.flatMap(Self.taskCount) == 5)
            #expect(Self.index(of: card, in: window.transcript) == Self.index(of: card, in: settled))
            let secondPrompt = try #require(window.transcript.firstIndex {
                $0.content == .userPrompt(text: "Second", attachments: [], origin: .app)
            })
            #expect(try #require(Self.index(of: card, in: window.transcript)) < secondPrompt)
            #expect(try #require(cards.last.flatMap { Self.index(of: $0, in: window.transcript) }) > secondPrompt)
            await backend.release()
            #expect(await window.waitUntilIdle())
            // A card is no artifact.
            #expect(window.fileArtifacts.isEmpty)

            // A new session shows no card, nor does a change outside a turn.
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            let newSessionID = window.current.sessionID
            #expect(newSessionID != sessionID)
            try? await orchestrator.registerSession(id: newSessionID, workingDirectory: workspace)
            let significant = try await orchestrator.createTasks(
                sessionID: newSessionID,
                tasks: [TaskDefinition(title: "First"), TaskDefinition(title: "Second")]
            )
            #expect(await eventually { window.snapshot?.taskGraph?.graph.id == significant.id })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            await runtime.shutdown()
        }
    }

    @Test("A graph that is not significant shows no card in a turn; /tasks adds a card that stays where it ran, which the turn's card never moves")
    func tasksCommandCard() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await runtime.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            // One pending task is not significant: no card in the turn.
            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })
            let graph = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Only")])
            #expect(await eventually { window.snapshot?.taskGraph?.graph.id == graph.id })
            #expect(window.snapshot?.taskGraph?.isSignificant == false)
            #expect(Self.taskCards(in: window.transcript).isEmpty)

            // /tasks beside the turn: a card of that graph, after its echo.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 1 })
            let requested = try #require(Self.taskCards(in: window.transcript).first)
            #expect(Self.taskCount(requested) == 1)
            let echo = try #require(window.transcript.lastIndex { $0.content == .commandLine("/tasks") })
            #expect(try #require(Self.index(of: requested, in: window.transcript)) > echo)

            // A significant change: the turn's card, after the /tasks card.
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Second")])
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 2 })
            let turnCard = try #require(Self.taskCards(in: window.transcript).last)
            #expect(turnCard.id != requested.id)
            #expect(Self.taskCount(turnCard) == 2)
            let requestedIndex = try #require(Self.index(of: requested, in: window.transcript))
            #expect(try #require(Self.index(of: turnCard, in: window.transcript)) > requestedIndex)

            // A row, then a change: the turn's card moves; the /tasks card
            // stays where it is, as it was.
            let marker = ChatSessionNotice.help(commandHelp: ["Card marker"])
            await Self.present(marker, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(marker) } })
            _ = try await orchestrator.createTasks(sessionID: sessionID, tasks: [TaskDefinition(title: "Third")])
            #expect(await eventually { Self.taskCards(in: window.transcript).last.flatMap(Self.taskCount) == 3 })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.map(\.id) == [requested.id, turnCard.id])
            #expect(cards.first == requested)
            #expect(Self.index(of: requested, in: window.transcript) == requestedIndex)
            let markerIndex = try #require(window.transcript.firstIndex { $0.content == .notice(marker) })
            #expect(try #require(Self.index(of: turnCard, in: window.transcript)) > markerIndex)
            await backend.release()
            #expect(await window.waitUntilIdle())

            // /tasks once the turn ended: one more card, the last row.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { Self.taskCards(in: window.transcript).count == 3 })
            let last = try #require(Self.taskCards(in: window.transcript).last)
            #expect(Self.taskCount(last) == 3)
            #expect(window.transcript.last?.id == last.id)
            #expect(Self.taskCards(in: window.transcript).prefix(2).map(\.id) == [requested.id, turnCard.id])

            // Another action of /tasks shows no card.
            let beforeShow = Self.taskCards(in: window.transcript)
            window.draft = "/tasks show nope"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(Self.taskCards(in: window.transcript) == beforeShow)

            // Without a graph: no card, only the command's notice.
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.epoch == window.current.epoch })
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.transcript.contains { $0.content == .notice(.noTaskGraph) } })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            await runtime.shutdown()
        }
    }

    @Test("/tasks in a turn shows its card once, even when the snapshot's graph is stale: the explicit overview never reaches the reducer")
    func tasksCommandInATurnShowsOneCard() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await window.waitUntilIdle())
            let orchestrator = await runtime.runner.taskOrchestrator
            let sessionID = window.current.sessionID
            try? await orchestrator.registerSession(id: sessionID, workingDirectory: workspace)

            await backend.hold()
            window.draft = "Busy"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(await eventually { window.isGenerating })

            // Without the observer the snapshot keeps its old graph (none): a
            // significant graph created now reaches no automatic overview, so
            // it shows no card of the turn.
            await window.current.controller.stopTaskGraphObserver()
            _ = try await orchestrator.createTasks(
                sessionID: sessionID,
                tasks: [TaskDefinition(title: "A"), TaskDefinition(title: "B")]
            )
            let before = ChatSessionNotice.help(commandHelp: ["Before /tasks"])
            await Self.present(before, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(before) } })
            #expect(Self.taskCards(in: window.transcript).isEmpty)
            #expect(window.snapshot?.taskGraph == nil)

            // /tasks beside the turn: exactly one card, the graph it read,
            // after its echo. The snapshots reach the window in order, so the
            // row presented after the card is behind any snapshot the explicit
            // overview would have produced.
            window.draft = "/tasks"
            window.submitDraft()
            #expect(await eventually { !Self.taskCards(in: window.transcript).isEmpty })
            let after = ChatSessionNotice.help(commandHelp: ["After /tasks"])
            await Self.present(after, in: window.sessionHost, slotID: window.slotID)
            #expect(await eventually { window.transcript.contains { $0.content == .notice(after) } })
            let cards = Self.taskCards(in: window.transcript)
            #expect(cards.count == 1)
            let card = try #require(cards.first)
            #expect(Self.taskCount(card) == 2)
            let echo = try #require(window.transcript.lastIndex { $0.content == .commandLine("/tasks") })
            #expect(try #require(Self.index(of: card, in: window.transcript)) > echo)
            // The explicit overview is the presenter's: the snapshot is as it was.
            #expect(window.snapshot?.taskGraph == nil)

            await backend.release()
            #expect(await window.waitUntilIdle())
            #expect(Self.taskCards(in: window.transcript).map(\.id) == [card.id])
            #expect(window.snapshot?.taskGraph == nil)
            await runtime.shutdown()
        }
    }

    @Test("The window presenter publishes the sub-agent overview around agent.* calls")
    func subAgentOverviewReachesTheReducer() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            await backend.script(prompt: "Delegate", events: [
                .toolCallStarted(DirectAgentToolCall(
                    id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}"
                )),
                .toolCallCompleted(
                    DirectAgentToolCall(id: "agent-call", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}"),
                    DirectAgentToolResult(output: "created", summary: "created")
                ),
            ])
            await backend.setSubAgents([
                DirectSubAgentRuntime.AgentSnapshot(
                    id: "agent-1",
                    rootSessionID: window.current.sessionID,
                    name: "Worker",
                    role: "developer",
                    status: .running,
                    pending: true,
                    latestOutput: nil,
                    latestError: nil,
                    createdAt: Date(),
                    updatedAt: Date()
                ),
            ])
            window.draft = "Delegate"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.subAgents.snapshots.map(\.id) == ["agent-1"] })
            #expect(window.snapshot?.subAgents.snapshots.map(\.id) == ["agent-1"])
            #expect(window.transcript.contains {
                if case let .toolCall(call, result) = $0.content {
                    return call.name == "agent.create" && result?.output == "created"
                }
                return false
            })
            await runtime.shutdown()
        }
    }

    @Test("/artifacts shows and hides the artifacts sidebar, beside a running turn too; with arguments it answers the core's notice")
    func artifactsTogglesTheSidebar() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(!window.isArtifactsSidebarPresented)
            #expect(window.fileArtifacts.isEmpty)

            // The toolbar and the menu toggle it directly.
            window.toggleArtifactsSidebar()
            #expect(window.isArtifactsSidebarPresented)
            window.toggleArtifactsSidebar()
            #expect(!window.isArtifactsSidebarPresented)

            // /artifacts shows it, then hides it: its echo, and no artifact notice.
            window.draft = "/artifacts"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            #expect(window.isArtifactsSidebarPresented)
            #expect(window.transcript.contains { $0.content == .commandLine("/artifacts") })
            window.run("/artifacts")
            #expect(await window.waitUntilIdle())
            #expect(!window.isArtifactsSidebarPresented)
            #expect(window.transcript.filter { $0.content == .commandLine("/artifacts") }.count == 2)
            #expect(!window.transcript.contains { Self.isArtifactHistoryNotice($0.content) })

            // With arguments: the core's notice, and no toggle.
            window.draft = "/artifacts all"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .notice(.artifactsTakeNoArguments) }
            })
            #expect(window.transcript.contains { $0.content == .commandLine("/artifacts all") })
            #expect(!window.isArtifactsSidebarPresented)

            // While a turn runs, /artifacts runs beside it instead of being refused.
            await backend.hold()
            window.draft = "Long"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(window.isBusy)
            window.draft = "/artifacts"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.isEmpty)
            #expect(await eventually { window.isArtifactsSidebarPresented })
            #expect(!window.transcript.contains {
                if case .local(_, isFailure: true) = $0.content { return true }
                return false
            })
            await backend.release()
            #expect(await window.waitUntilIdle())

            // A new session keeps the sidebar as the operator left it.
            let firstEpoch = window.current.epoch
            window.startNewSession()
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.current.epoch != firstEpoch && window.snapshot?.epoch == window.current.epoch })
            #expect(window.isArtifactsSidebarPresented)
            #expect(window.fileArtifacts.isEmpty)
            #expect(!window.transcript.contains { Self.isArtifactHistoryNotice($0.content) })
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
            #expect(window.status.modelID == "zen-app-model")

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
            // The host shut the runner (and the backend) down, fencing the
            // turn, before the window's line, and its held turn, was
            // cancelled.
            #expect(backend.lifecycle.events == [.backendShutDown, .heldTurnCancelled])
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

    private static func isHelpNotice(_ content: ZenTranscriptItem.Content) -> Bool {
        if case let .notice(notice) = content, case .help = notice {
            return true
        }
        return false
    }

    /// The task-graph cards of `transcript`, in order.
    private static func taskCards(in transcript: [ZenTranscriptItem]) -> [ZenTranscriptItem] {
        transcript.filter {
            if case .taskGraph = $0.content { return true }
            return false
        }
    }

    /// The number of tasks of the card `item`; `nil` for another row.
    private static func taskCount(_ item: ZenTranscriptItem) -> Int? {
        guard case let .taskGraph(overview) = item.content else { return nil }
        return overview.graph.tasks.count
    }

    /// The index of the row with `item`'s id in `transcript`.
    private static func index(of item: ZenTranscriptItem, in transcript: [ZenTranscriptItem]) -> Int? {
        transcript.firstIndex { $0.id == item.id }
    }

    /// Presents `notice` on the reducer of `slotID`: a log row that arrives
    /// while a turn runs.
    @ChatSessionActor
    private static func present(_ notice: ChatSessionNotice, in sessionHost: ChatSessionHost, slotID: ChatSlotID) async {
        await sessionHost.reducer(in: slotID)?.presentSessionNotice(notice)
    }

    /// `true` for the notices of the shared `/artifacts`, which writes the
    /// artifact history in the transcript.
    private static func isArtifactHistoryNotice(_ content: ZenTranscriptItem.Content) -> Bool {
        guard case let .notice(notice) = content else { return false }
        switch notice {
        case .fileArtifacts, .noFileArtifacts:
            return true
        default:
            return false
        }
    }

    /// A running sub-agent of the root session `root`.
    private static func subAgent(_ id: String, root: String) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            rootSessionID: root,
            name: "Worker \(id)",
            role: "developer",
            status: .running,
            pending: true,
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
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
            .appendingPathComponent("zen-app-session-\(UUID().uuidString)", isDirectory: true)
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
