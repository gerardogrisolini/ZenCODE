//
//  ZenWorkspaceWindowTests.swift
//  ZenAppSessionTests
//
//  One system window holds several sessions: New Session adds one to that
//  window, even while a turn runs, clean as the first one (never with the
//  selection of another session), and each session keeps its own runner,
//  transcript, and turn.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

extension ZenWindowSessionTests {
    @Test("New Session during a held turn adds a selected session to the same window that starts clean, without the selection of the selected one")
    func newSessionDuringATurnStaysInTheSameWindowAndStartsClean() async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            await window.openFirstSession()
            let first = try #require(window.selectedSession)
            #expect(await eventually { first.snapshot != nil && first.epoch == first.current.epoch })
            // The selection every session of the window starts from.
            let clean = try #require(await Self.selection(of: first, in: runtime))
            first.draft = "/tools shell"
            first.submitDraft()
            #expect(await first.waitUntilIdle())
            #expect(await eventually { first.snapshot?.selection.toolKeys == ["shell"] })
            let selected = try #require(await Self.selection(of: first, in: runtime))
            #expect(selected != clean)

            await backend.hold()
            first.draft = "First prompt"
            first.submitDraft()
            #expect(await backend.waitUntilHeld())
            #expect(first.isBusy)

            let second = try #require(await window.openNewSession())
            #expect(window.sessions.count == 2)
            #expect(window.sessions.first === first)
            #expect(window.sessions.last === second)
            #expect(window.selectedSession === second)
            #expect(second !== first)
            #expect(second.id != first.id)
            #expect(second.slotID != first.slotID)
            #expect(second.runner !== first.runner)
            #expect(second.current.sessionID != first.current.sessionID)
            #expect(first.isBusy)
            #expect(await backend.isHolding)
            #expect(!backend.lifecycle.events.contains(.heldTurnCancelled))
            // The new session starts clean: not with the tools of the
            // selected one, which keeps its own.
            let opened = try #require(await Self.selection(of: second, in: runtime))
            #expect(opened == clean)
            #expect(opened.toolKeys != ["shell"])
            #expect(await Self.selection(of: first, in: runtime) == selected)

            await backend.hold()
            second.draft = "Second prompt"
            second.submitDraft()
            #expect(await waitUntil("both sessions reached the backend") {
                await backend.prompts.count == 2
            })
            #expect(first.isBusy && second.isBusy)
            #expect(!first.transcript.contains {
                $0.content == .userPrompt(text: "Second prompt", attachments: [], origin: .app)
            })
            #expect(!second.transcript.contains {
                $0.content == .userPrompt(text: "First prompt", attachments: [], origin: .app)
            })

            await backend.release()
            #expect(await first.waitUntilIdle())
            #expect(await second.waitUntilIdle())
            #expect(await eventually {
                first.transcript.contains {
                    $0.content == .assistantText("Scripted answer to First prompt", isStreaming: false)
                } && second.transcript.contains {
                    $0.content == .assistantText("Scripted answer to Second prompt", isStreaming: false)
                }
            })
            #expect(!backend.lifecycle.events.contains(.heldTurnCancelled))
            #expect(window.sessions.count == 2)
            #expect(window.selectedSession === second)
            await runtime.shutdown()
        }
    }

    @Test("A typed sessions new replaces only its own session inside the window")
    func typedNewSessionReplacesOnlyItsOwnSession() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            await window.openFirstSession()
            let first = try #require(window.selectedSession)
            let second = try #require(await window.openNewSession())
            let firstID = first.current.sessionID
            let secondID = second.current.sessionID
            second.draft = "Other session draft"

            window.select(first)
            first.draft = "/sessions new"
            first.submitDraft()
            #expect(await first.waitUntilIdle())
            #expect(await eventually { first.current.sessionID != firstID })
            #expect(window.sessions.count == 2)
            #expect(window.sessions.first === first)
            #expect(window.sessions.last === second)
            #expect(window.selectedSession === first)
            #expect(second.current.sessionID == secondID)
            #expect(second.draft == "Other session draft")
            await runtime.shutdown()
        }
    }

    @Test("Selecting and closing sessions keeps one window until the last session exits")
    func selectionAndCloseStayInOneWindow() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            await window.openFirstSession()
            let first = try #require(window.selectedSession)
            let second = try #require(await window.openNewSession())
            let third = try #require(await window.openNewSession())
            #expect(window.sessions.map(\.id) == [first.id, second.id, third.id])

            window.select(first)
            #expect(window.selectedSession === first)
            window.select(second)
            #expect(window.selectedSession === second)
            await window.closeSession(second)
            #expect(window.sessions.map(\.id) == [first.id, third.id])
            #expect(window.selectedSession === third)
            #expect(second.isClosed)
            #expect(!window.closeRequested)

            third.draft = "/exit"
            third.submitDraft()
            #expect(await eventually { window.sessions.count == 1 })
            #expect(window.selectedSession === first)
            #expect(third.isClosed)
            #expect(!first.isClosed)
            #expect(!window.closeRequested)

            first.draft = "/exit"
            first.submitDraft()
            #expect(await eventually { window.closeRequested })
            #expect(window.sessions.isEmpty)
            #expect(window.selectedSession == nil)
            #expect(first.isClosed)
            await runtime.shutdown()
        }
    }

    @Test("Choosing a saved session already open in the window selects it instead of loading it twice")
    func savedSessionAlreadyOpenIsSelected() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            await window.openFirstSession()
            let first = try #require(window.selectedSession)
            first.draft = "Saved content"
            first.submitDraft()
            #expect(await first.waitUntilIdle())
            first.saveSession()
            #expect(await first.waitUntilIdle())
            #expect(await eventually { first.currentSavedSessionName != nil })
            let name = try #require(first.currentSavedSessionName)
            let firstID = first.current.sessionID

            let second = try #require(await window.openNewSession())
            let secondID = second.current.sessionID
            #expect(window.selectedSession === second)
            window.showSavedSession(named: name)
            #expect(window.selectedSession === first)
            #expect(window.sessions.count == 2)
            #expect(first.current.sessionID == firstID)
            #expect(second.current.sessionID == secondID)
            #expect(!second.isBusy)
            await runtime.shutdown()
        }
    }

    /// The selection the controller holds now; a window snapshot can lag a
    /// fresh session's tool keys.
    private static func selection(
        of session: ZenWindowSession,
        in runtime: ZenAppRuntime
    ) async -> ChatSessionSelection? {
        await runtime.sessionHost.incarnation(in: session.slotID)?.controller.selection
    }
}
