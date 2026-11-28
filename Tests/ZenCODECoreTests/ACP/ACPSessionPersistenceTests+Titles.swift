//
//  ACPSessionPersistenceTests+Titles.swift
//  ZenCODE
//
//  The title of an ACP session (`session_info_update`), as codex-acp gives it:
//  there is no placeholder (not the name of the folder), the first prompt of
//  the conversation gives it once, and later prompts never change it. A
//  restored session that already has a title (the name it was saved under, or
//  the first prompt of its history) announces it once and keeps it.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension ACPSessionPersistenceTests {
    /// `session/new` names nothing; the first prompt names the session after
    /// its first line; the second prompt leaves the title as it is.
    @Test
    func aNewSessionIsTitledByItsFirstPromptOnly() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            // Not the name of the folder, not anything: no title yet.
            #expect(wire.titles(sessionID: sessionID).isEmpty)

            await bridge.handleMessage(Self.promptRequest(
                id: 2, sessionID: sessionID, text: "First question\nwith a second line"
            ))
            #expect(wire.titles(sessionID: sessionID) == ["First question"])
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "Second question"))
            #expect(wire.stopReason(id: 3) == "end_turn")
            #expect(wire.titles(sessionID: sessionID) == ["First question"])
            await bridge.shutdown()
        }
    }

    /// `session/load` of a saved session announces the name it was saved under,
    /// once, after its reply; the prompts that follow keep that title.
    @Test(arguments: ["session/load", "session/resume"])
    func aRestoredSessionAnnouncesItsSavedNameOnceAndKeepsIt(method: String) async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "What is the capital of Italy?")
            let savedName = try #require(
                TerminalSessionStore.savedSessions(for: workspace).first { $0.sessionID == sessionID }?.name
            )

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest(method, id: 1, sessionID: sessionID, workspace: workspace))
            #expect(wire.titles(sessionID: sessionID) == [savedName])
            // After the reply, and never the folder the session was opened in.
            let responseIndex = try #require(wire.index(ofResponse: 1))
            let titleIndex = try #require((0 ..< wire.count).first { index in
                wire.message(at: index)?["params"]?.objectValue?["update"]?.objectValue?["sessionUpdate"]?
                    .acpStringValue == "session_info_update"
            })
            #expect(titleIndex > responseIndex)

            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "And of France?"))
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "And of Spain?"))
            #expect(wire.stopReason(id: 3) == "end_turn")
            #expect(wire.titles(sessionID: sessionID) == [savedName])
            await bridge.shutdown()
        }
    }

    /// A saved session the user named by hand is announced under that name.
    @Test
    func aSessionSavedByHandAnnouncesItsName() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let manual = Self.manualSession(name: "Hand named", sessionID: "manual-session", workspace: workspace)
            _ = try TerminalSessionStore.save(manual)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest(
                "session/resume", id: 1, sessionID: "manual-session", workspace: workspace
            ))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: "manual-session", text: "Next"))
            #expect(wire.titles(sessionID: "manual-session") == ["Hand named"])
            await bridge.shutdown()
        }
    }

    /// The history a client sends with a restore gives the title when no
    /// saved name does: the first prompt of the history, not a later prompt.
    @Test
    func aRestoredSessionWithTheClientsHistoryIsTitledByItsFirstPrompt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            var request = Self.restoreRequest("session/resume", id: 1, sessionID: "client-session", workspace: workspace)
            var params = try #require(request["params"] as? [String: Any])
            params["history"] = [
                ["role": "user", "content": "Kept by the client"],
                ["role": "assistant", "content": "Client answer"],
                ["role": "user", "content": "A later question"],
                ["role": "assistant", "content": "Another answer"],
            ] as [[String: Any]]
            request["params"] = params
            await bridge.handleMessage(request)
            #expect(wire.titles(sessionID: "client-session") == ["Kept by the client"])

            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: "client-session", text: "Next"))
            #expect(wire.titles(sessionID: "client-session") == ["Kept by the client"])
            await bridge.shutdown()
        }
    }

    /// A restored session with nothing to name it by announces no title; its
    /// first prompt names it, and the second prompt does not rename it.
    @Test
    func aRestoredSessionWithoutAnyHistoryIsTitledByItsFirstPrompt() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.restoreRequest(
                "session/load", id: 1, sessionID: "unknown-session", workspace: workspace
            ))
            #expect(wire.index(ofResponse: 1) != nil)
            #expect(wire.titles(sessionID: "unknown-session").isEmpty)

            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: "unknown-session", text: "Fresh start"))
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: "unknown-session", text: "Something else"))
            #expect(wire.titles(sessionID: "unknown-session") == ["Fresh start"])
            await bridge.shutdown()
        }
    }

    /// A restore of a session that is live announces its title again, once,
    /// for the client that attached; a session without title announces none.
    @Test
    func aRestoreOfALiveSessionAnnouncesItsTitleAgainOnce() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))

            // Without a title there is nothing to announce.
            await bridge.handleMessage(Self.restoreRequest("session/resume", id: 2, sessionID: sessionID, workspace: workspace))
            #expect(wire.titles(sessionID: sessionID).isEmpty)

            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: sessionID, text: "Live question"))
            await bridge.handleMessage(Self.restoreRequest("session/resume", id: 4, sessionID: sessionID, workspace: workspace))
            #expect(wire.titles(sessionID: sessionID) == ["Live question", "Live question"])

            await bridge.handleMessage(Self.promptRequest(id: 5, sessionID: sessionID, text: "Another"))
            #expect(wire.titles(sessionID: sessionID) == ["Live question", "Live question"])
            await bridge.shutdown()
        }
    }
}
