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

    @Test("A worktree request adds a session to its registered window without touching the source")
    func worktreeRequestReusesWorkspaceWindow() async throws {
        try await withRuntime { runtime, _, workspace in
            let source = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            let destination = ZenWorkspaceWindow(runtime: runtime, workspace: workspace.appendingPathComponent("worktree"))
            runtime.registerWorkspaceWindow(source)
            runtime.registerWorkspaceWindow(destination)
            await source.openFirstSession()
            await destination.openFirstSession()
            let sourceSession = try #require(source.selectedSession)
            let first = try #require(destination.selectedSession)
            var openedWindow = false
            await runtime.openWorktreeSession(in: destination.workspace) { _ in openedWindow = true }
            #expect(!openedWindow)
            #expect(source.sessions.count == 1)
            #expect(source.selectedSession === sourceSession)
            #expect(destination.sessions.count == 2)
            #expect(destination.selectedSession !== first)
            #expect(destination.selectedSession?.workspace == destination.workspace)
            await source.close()
            await destination.close()
            await runtime.shutdown()
        }
    }

    @Test("Closing the last session of a menu worktree asks without closing another workspace")
    func lastMenuWorktreeSessionShowsLocalClosure() async throws {
        try await withRuntime { runtime, _, workspace in
            let worktree = try Self.menuWorktree(in: workspace)
            let source = ZenWorkspaceWindow(runtime: runtime, workspace: workspace)
            let destination = ZenWorkspaceWindow(runtime: runtime, workspace: worktree.directory)
            runtime.registerWorkspaceWindow(destination)
            await source.openFirstSession()
            await destination.openFirstSession()
            let other = try #require(source.selectedSession)
            let first = try #require(destination.selectedSession)
            #expect(await runtime.openWorktreeSession(worktree) { _ in Issue.record("Opened a duplicate workspace window") })
            let last = try #require(destination.selectedSession)
            #expect(last !== first)

            var presentations = 0
            runtime.showWorktreeClosure = { presentations += 1 }
            await destination.closeSession(first)
            #expect(runtime.displayedWorktreeClosure == nil)
            #expect(!destination.closeRequested)
            #expect(presentations == 0)

            await destination.closeSession(last)
            #expect(destination.closeRequested)
            let closure = try #require(runtime.displayedWorktreeClosure)
            #expect(closure.worktree == worktree)
            #expect(presentations == 1)
            await closure.decide(.keep) // Keep performs no Git operations.
            runtime.dismissMenuWorktreeClosure(closure)
            #expect(runtime.displayedWorktreeClosure == nil)
            #expect(!runtime.hasPendingMenuWorktreeClosure)
            #expect(!runtime.isShutDown)
            #expect(!other.isClosed)
            #expect(source.selectedSession === other)
            await runtime.shutdown()
        }
    }

    @Test("Native window close waits for other sessions in the same worktree, including nested workspaces")
    func nativeCloseWithAnotherMenuWorktreeWorkspace() async throws {
        try await withRuntime { runtime, _, workspace in
            let worktree = try Self.menuWorktree(in: workspace)
            let nested = worktree.directory.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let destination = ZenWorkspaceWindow(runtime: runtime, workspace: worktree.directory)
            let other = ZenWorkspaceWindow(runtime: runtime, workspace: nested)
            #expect(await runtime.openWorktreeSession(worktree) { _ in })
            runtime.registerWorkspaceWindow(destination)
            await destination.openFirstSession()
            await other.openFirstSession()
            _ = try #require(other.selectedSession)

            destination.beginSystemWindowClose()
            #expect(runtime.hasPendingMenuWorktreeClosure)
            await destination.close()
            #expect(runtime.displayedWorktreeClosure == nil)
            other.beginSystemWindowClose()
            #expect(runtime.hasPendingMenuWorktreeClosure)
            await other.close()
            let closure = try #require(runtime.displayedWorktreeClosure)
            #expect(closure.worktree == worktree)
            runtime.dismissMenuWorktreeClosure(closure)
            #expect(!runtime.hasPendingMenuWorktreeClosure)
            #expect(!runtime.isShutDown)
            await runtime.shutdown()
        }
    }

    @Test("A worktree close reserves its workspace and waits for in-flight Git preparation")
    func reopeningMenuWorktreeWhileClosureIsPending() async throws {
        try await withRuntime { runtime, _, workspace in
            let worktree = try Self.menuWorktree(in: workspace)
            let destination = ZenWorkspaceWindow(runtime: runtime, workspace: worktree.directory)
            #expect(await runtime.openWorktreeSession(worktree) { _ in })
            runtime.registerWorkspaceWindow(destination)
            await destination.openFirstSession()
            _ = try #require(destination.selectedSession)
            let started = runtime.beginWorktreePreparation()
            try #require(started)
            await destination.close()
            guard let closure = runtime.displayedWorktreeClosure else {
                runtime.endWorktreePreparation()
                Issue.record("Expected a local worktree decision")
                await runtime.shutdown()
                return
            }
            #expect(!closure.canModifyWorktree)
            #expect(!runtime.canOpenWorkspace(worktree.directory))
            let reopened = await runtime.openWorktreeSession(worktree) { _ in
                Issue.record("Opened a window while the decision reserved its worktree")
            }
            #expect(!reopened)
            runtime.endWorktreePreparation()
            #expect(closure.canModifyWorktree)

            runtime.dismissMenuWorktreeClosure(closure)
            #expect(runtime.canOpenWorkspace(worktree.directory))
            let session = try await runtime.openWindow(workspace: worktree.directory)
            #expect(!session.isClosed)
            await session.close()
            #expect(runtime.displayedWorktreeClosure !== closure)
            #expect(runtime.displayedWorktreeClosure?.worktree == worktree)
            await runtime.shutdown()
        }
    }

    private static func menuWorktree(in workspace: URL) throws -> AgentWorktree {
        let directory = workspace.appendingPathComponent("temporary-worktree", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return AgentWorktree(name: "feature", directory: directory)
    }

    @Test("Worktree requests queued before window registration each create a session")
    func worktreeRequestsWhileWindowOpens() async throws {
        try await withRuntime { runtime, _, workspace in
            let target = workspace.appendingPathComponent("worktree")
            var opened: [URL] = []
            await runtime.openWorktreeSession(in: target) { opened.append($0) }
            await runtime.openWorktreeSession(in: target) { opened.append($0) }
            #expect(opened == [target.standardizedFileURL])
            let destination = ZenWorkspaceWindow(runtime: runtime, workspace: target)
            runtime.registerWorkspaceWindow(destination)
            await destination.openFirstSession()
            #expect(await eventually { destination.sessions.count == 2 })
            #expect(destination.sessions.allSatisfy { $0.workspace == target })
            await destination.close()
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
