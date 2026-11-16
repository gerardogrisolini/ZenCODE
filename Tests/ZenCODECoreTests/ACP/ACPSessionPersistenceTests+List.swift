//
//  ACPSessionPersistenceTests+List.swift
//  ZenCODE
//
//  Tests of `session/list` for saved ACP sessions, with the fixture helpers
//  only these tests use.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension ACPSessionPersistenceTests {
    // MARK: - session/list

    /// With nothing saved, `session/list` answers an empty list without
    /// `nextCursor`, with or without `cwd` and without `params`, and creates
    /// nothing; a `null` `cwd` or `cursor` is no filter and the first page.
    @Test
    func listingWithNothingSavedAnswersAnEmptyList() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)

            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            await bridge.handleMessage(["jsonrpc": "2.0", "id": 3, "method": "session/list"])
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": NSNull(), "cursor": NSNull()]))

            for id in 1...4 {
                #expect(wire.result(id: id) == ["sessions": .array([])])
            }
            #expect(!FileManager.default.fileExists(atPath: Self.sessionsDirectory(in: support).path))
            await bridge.shutdown()
        }
    }

    /// After a turn the session is listed with its id, the working directory
    /// it was saved in, the name its first prompt gave it as `title`, and the
    /// moment it was saved as `updatedAt`, in the format of
    /// `session_info_update`.
    @Test
    func aSavedTurnIsListedWithItsIdWorkingDirectoryTitleAndSaveTime() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "What is the capital of Italy?")
            let saved = try #require(try TerminalSessionStore.savedSessions(for: workspace).first)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            let updatedAt = ISO8601DateFormatter().string(from: saved.savedAt)
            #expect(wire.result(id: 1) == ["sessions": .array([.object([
                "sessionId": .string(sessionID),
                "cwd": .string(saved.workingDirectoryPath),
                "title": .string("What is the capital of Italy?"),
                "updatedAt": .string(updatedAt),
            ])])])
            #expect(wire.result(id: 2) == ["sessions": .array([.object([
                "sessionId": .string(sessionID),
                "cwd": .string(workspace.path),
                "title": .string("What is the capital of Italy?"),
                "updatedAt": .string(updatedAt),
            ])])])
            let parsed = try #require(ISO8601DateFormatter().date(from: updatedAt))
            #expect(abs(parsed.timeIntervalSince(saved.savedAt)) < 1)
            await bridge.shutdown()
        }
    }

    /// The sessions the user saved with `/sessions` are not listed, even
    /// under the id of an ACP session, and the files ACP saved for one id
    /// give one entry: the most recently saved.
    @Test
    func explicitSavesAreNotListedAndAnIdIsListedOnceWithItsNewestSave() async throws {
        try await Self.withSupportDirectory { _, workspace in
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Kept by the user", sessionID: "manual-only", workspace: workspace))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Older save", sessionID: "shared", workspace: workspace, savedAt: 100))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Newer save", sessionID: "shared", workspace: workspace, savedAt: 200))
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Newest by hand", sessionID: "shared", workspace: workspace, savedAt: 300))

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            for id in 1...2 {
                let sessions = try #require(Self.listedSessions(wire, id: id))
                #expect(sessions.map { $0["sessionId"]?.acpStringValue } == ["shared"])
                #expect(sessions.first?["title"] == .string("Newer save"))
                #expect(sessions.first?["updatedAt"] == .string(
                    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 200))
                ))
            }
            await bridge.shutdown()
        }
    }

    /// `cwd` lists the sessions saved in exactly that working directory: not
    /// those of another project, nor those of another folder with the same
    /// name, whose sessions share the project's directory. Without `cwd`
    /// every project is listed.
    @Test
    func theWorkingDirectoryFilterMatchesTheExactPath() async throws {
        try await Self.withSupportDirectory { support, _ in
            let root = support.deletingLastPathComponent()
            let alpha = try Self.makeDirectory(root, "first/Alpha")
            let beta = try Self.makeDirectory(root, "second/Beta")
            let sameA = try Self.makeDirectory(root, "a/Same")
            let sameB = try Self.makeDirectory(root, "b/Same")
            #expect(TerminalSessionStore.sessionsDirectoryURL(for: sameA) == TerminalSessionStore.sessionsDirectoryURL(for: sameB))
            for (sessionID, workspace) in [("alpha", alpha), ("beta", beta), ("same-a", sameA), ("same-b", sameB)] {
                _ = try TerminalSessionStore.save(Self.autosavedSession(name: sessionID, sessionID: sessionID, workspace: workspace))
            }

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: alpha)
            await bridge.handleMessage(Self.listRequest(id: 1, params: ["cwd": alpha.path]))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": beta.path]))
            await bridge.handleMessage(Self.listRequest(id: 3, params: ["cwd": sameA.path]))
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": sameB.path + "/"]))
            await bridge.handleMessage(Self.listRequest(id: 5))
            await bridge.handleMessage(Self.listRequest(id: 6, params: ["cwd": root.appendingPathComponent("c/Same").path]))

            #expect(Self.listedIDs(wire, id: 1) == ["alpha"])
            #expect(Self.listedIDs(wire, id: 2) == ["beta"])
            #expect(Self.listedIDs(wire, id: 3) == ["same-a"])
            #expect(Self.listedIDs(wire, id: 4) == ["same-b"])
            // The `cwd` the client sent, as it sent it.
            #expect(Self.listedSessions(wire, id: 4)?.first?["cwd"] == .string(sameB.path + "/"))
            #expect(Self.listedIDs(wire, id: 5) == ["alpha", "beta", "same-a", "same-b"])
            #expect(Self.listedSessions(wire, id: 5)?.first { $0["sessionId"] == .string("same-b") }?["cwd"]
                == .string(Self.resolvedPath(sameB)))
            #expect(Self.listedIDs(wire, id: 6) == [])
            await bridge.shutdown()
        }
    }

    /// A `cwd` through a symbolic link lists the sessions saved there, which
    /// are saved under the resolved directory, as `session/new` and
    /// `session/load` resolve it: every entry carries the `cwd` the client
    /// sent, and `session/load` with it restores the conversation.
    @Test
    func aWorkingDirectoryThroughASymbolicLinkListsAndLoadsItsSessions() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let link = support.deletingLastPathComponent().appendingPathComponent("linked-project", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace)
            let resolvedPath = Self.resolvedPath(link)
            #expect(resolvedPath != link.path)
            #expect(resolvedPath == Self.resolvedPath(workspace))
            let sessionID = try await Self.runFirstProcess(workspace: link, prompt: "Through the link")
            #expect(try TerminalSessionStore.savedSessions(for: workspace).map(\.workingDirectoryPath) == [resolvedPath])

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: link)
            await bridge.handleMessage(Self.listRequest(id: 1, params: ["cwd": link.path]))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            await bridge.handleMessage(Self.listRequest(id: 3))

            let entry = try #require(Self.listedSessions(wire, id: 1)?.first)
            #expect(Self.listedIDs(wire, id: 1) == [sessionID])
            #expect(entry["cwd"] == .string(link.path))
            #expect(Self.listedSessions(wire, id: 2)?.first?["cwd"] == .string(workspace.path))
            #expect(Self.listedSessions(wire, id: 3)?.first?["cwd"] == .string(resolvedPath))

            let cwd = try #require(entry["cwd"]?.acpStringValue)
            await bridge.handleMessage(Self.restoreRequest(
                "session/load",
                id: 4,
                sessionID: sessionID,
                workspace: URL(fileURLWithPath: cwd)
            ))
            let responseIndex = try #require(wire.index(ofResponse: 4))
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "Through the link"),
                .init(kind: "agent_message_chunk", text: "reply to: Through the link"),
            ])
            await bridge.shutdown()
        }
    }

    /// A `cwd` that is not a string with an absolute path, and a `cursor` that
    /// is not a string a reply gave, are invalid parameters.
    @Test
    func anInvalidWorkingDirectoryOrCursorIsInvalidParams() async throws {
        try await Self.withSupportDirectory { _, workspace in
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace))
            let badHex = Data(#"{"savedAt":"zzzzzzzzzzzzzzzz","sessionId":"listed"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let invalidParams: [[String: JSONValue]] = [
                ["cwd": .string("relative/path")],
                ["cwd": .string("~/Projects")],
                ["cwd": .string("")],
                ["cwd": .number(42)],
                ["cwd": .object(["path": .string(workspace.path)])],
                ["cursor": .number(42)],
                ["cursor": .string("")],
                ["cursor": .string("not a cursor!")],
                ["cursor": .string("Zm9v")],
                ["cursor": .string(badHex)],
            ]

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            for (offset, params) in invalidParams.enumerated() {
                await bridge.handleMessage(Self.listRequest(id: offset + 1, params: params.mapValues(\.jsonObject)))
            }

            for id in 1...invalidParams.count {
                #expect(wire.error(id: id)?["code"] == .number(-32602), "request \(id)")
                #expect(wire.result(id: id) == nil, "request \(id)")
            }
            await bridge.shutdown()
        }
    }

    /// The most recently saved session comes first; sessions saved at the
    /// same moment come in ascending order of their id.
    @Test
    func theListIsOrderedByLastSaveThenBySessionID() async throws {
        try await Self.withSupportDirectory { _, workspace in
            for (sessionID, savedAt) in [("session-b", 300.0), ("session-c", 100.0), ("session-a", 300.0), ("session-d", 200.0)] {
                _ = try TerminalSessionStore.save(Self.autosavedSession(
                    name: "Name of \(sessionID)",
                    sessionID: sessionID,
                    workspace: workspace,
                    savedAt: savedAt
                ))
            }

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))

            #expect(Self.listedIDs(wire, id: 1) == ["session-a", "session-b", "session-d", "session-c"])
            #expect(wire.result(id: 1)?["nextCursor"] == nil)
            await bridge.shutdown()
        }
    }

    /// More than a page of sessions: pages of 50 with `nextCursor`, the last
    /// one without it, and walking them gives every session once, in order,
    /// also where sessions saved at the same moment, distinct only below the
    /// second, straddle the end of a page.
    @Test
    func pagesOfFiftyWalkEverySessionOnceInOrder() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let count = 120
            var expected: [(id: String, savedAt: Date)] = []
            for index in 0..<count {
                let sessionID = String(format: "paged-%03d", (index * 37) % count)
                // Three sessions per moment, the moments a microsecond apart.
                let savedAt = Date(timeIntervalSince1970: 1_700_000_000.25 + Double(index / 3) * 0.000_001)
                _ = try TerminalSessionStore.save(Self.autosavedSession(
                    name: "Paged \(sessionID)",
                    sessionID: sessionID,
                    workspace: workspace,
                    savedAt: savedAt.timeIntervalSince1970
                ))
                expected.append((sessionID, savedAt))
            }
            _ = try TerminalSessionStore.save(Self.manualSession(name: "Not listed", sessionID: "manual", workspace: workspace))
            let savedAtByID = Dictionary(uniqueKeysWithValues: try TerminalSessionStore.savedSessions(for: workspace).map {
                ($0.sessionID, $0.savedAt)
            })
            let expectedOrder = expected
                .map { (id: $0.id, savedAt: savedAtByID[$0.id] ?? $0.savedAt) }
                .sorted { $0.savedAt != $1.savedAt ? $0.savedAt > $1.savedAt : $0.id < $1.id }
                .map(\.id)

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            var walked: [String] = []
            var pageSizes: [Int] = []
            var cursor: String?
            var requestID = 0
            repeat {
                requestID += 1
                await bridge.handleMessage(Self.listRequest(
                    id: requestID,
                    params: cursor.map { ["cwd": workspace.path, "cursor": $0] } ?? ["cwd": workspace.path]
                ))
                let ids = try #require(Self.listedIDs(wire, id: requestID))
                walked += ids
                pageSizes.append(ids.count)
                cursor = wire.result(id: requestID)?["nextCursor"]?.acpStringValue
            } while cursor != nil && requestID < 10

            #expect(pageSizes == [50, 50, 20])
            #expect(walked == expectedOrder)
            #expect(Set(walked).count == count)

            // Without `cwd` the same walk.
            await bridge.handleMessage(Self.listRequest(id: 100))
            let firstPage = try #require(Self.listedIDs(wire, id: 100))
            #expect(firstPage == Array(expectedOrder.prefix(50)))
            let nextCursor = try #require(wire.result(id: 100)?["nextCursor"]?.acpStringValue)
            await bridge.handleMessage(Self.listRequest(id: 101, params: ["cursor": nextCursor]))
            #expect(Self.listedIDs(wire, id: 101) == Array(expectedOrder.dropFirst(50).prefix(50)))
            await bridge.shutdown()
        }
    }

    /// What is not a session file is not listed and fails nothing: an
    /// unreadable file, hidden and temporary files, DS4 checkpoints, a
    /// directory, and a file among the project directories.
    @Test
    func filesThatAreNotSessionsAreNotListed() async throws {
        try await Self.withSupportDirectory { support, workspace in
            let listed = Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace)
            _ = try TerminalSessionStore.save(listed)
            let directory = TerminalSessionStore.sessionsDirectoryURL(for: workspace)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let hidden = try encoder.encode(Self.autosavedSession(name: "Hidden", sessionID: "hidden", workspace: workspace))
            try Data("not a property list".utf8).write(to: directory.appendingPathComponent("broken.session"))
            try hidden.write(to: directory.appendingPathComponent(".hidden.session"))
            try hidden.write(to: directory.appendingPathComponent("pending.session.tmp"))
            try hidden.write(to: directory.appendingPathComponent("Listed.ds4kv"))
            try hidden.write(to: directory.appendingPathComponent("Listed.ds4kv.tmp.1"))
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("nested.session", isDirectory: true),
                withIntermediateDirectories: true
            )
            try hidden.write(to: Self.sessionsDirectory(in: support).appendingPathComponent("stray.session"))

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))

            #expect(Self.listedIDs(wire, id: 1) == ["listed"])
            #expect(Self.listedIDs(wire, id: 2) == ["listed"])
            await bridge.shutdown()
        }
    }

    /// A session `session/delete` deleted is no longer listed; the others are.
    @Test
    func aSessionDeletedWithSessionDeleteIsNoLongerListed() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let deletedID = try await Self.runFirstProcess(workspace: workspace, prompt: "Delete me")
            let keptID = try await Self.runFirstProcess(workspace: workspace, prompt: "Keep me")

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            await bridge.handleMessage(Self.deleteRequest(id: 2, sessionID: deletedID))
            await bridge.handleMessage(Self.listRequest(id: 3))
            await bridge.handleMessage(Self.listRequest(id: 4, params: ["cwd": workspace.path]))

            #expect(Set(Self.listedIDs(wire, id: 1) ?? []) == [deletedID, keptID])
            #expect(wire.result(id: 2) == [:])
            #expect(Self.listedIDs(wire, id: 3) == [keptID])
            #expect(Self.listedIDs(wire, id: 4) == [keptID])
            await bridge.shutdown()
        }
    }

    /// A session deleted from `/sessions` is no longer listed.
    @Test
    func aSessionDeletedFromSessionsIsNoLongerListed() async throws {
        try await withChatHarness(catalog: .hosted(agents: [ChatTestFixtures.developer, Self.harnessAgent])) { harness in
            let wire = ACPPersistenceWire()
            let bridge = try Self.makeHarnessBridge(wire: wire, workspace: harness.workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: harness.workspace))
            let sessionID = try #require(wire.sessionID(ofResponse: 1))
            await bridge.handleMessage(Self.promptRequest(id: 2, sessionID: sessionID, text: "Delete me from sessions"))
            await bridge.shutdown()

            let restartedWire = ACPPersistenceWire()
            let restarted = try Self.makeHarnessBridge(wire: restartedWire, workspace: harness.workspace)
            await restarted.handleMessage(Self.listRequest(id: 1))
            #expect(Self.listedIDs(restartedWire, id: 1) == [sessionID])

            let outcome = try await harness.controller.deleteSavedSessions(names: ["Delete me from sessions"])
            #expect(outcome.notices == [.sessionDeleted(name: "Delete me from sessions")])

            await restarted.handleMessage(Self.listRequest(id: 2))
            await restarted.handleMessage(Self.listRequest(id: 3, params: ["cwd": harness.workspace.path]))
            #expect(restartedWire.result(id: 2) == ["sessions": .array([])])
            #expect(restartedWire.result(id: 3) == ["sessions": .array([])])
            await restarted.shutdown()
        }
    }

    /// After a restart, the client lists the sessions and reopens one with
    /// the `sessionId` and `cwd` of its entry: `session/load` replays the
    /// conversation and the next prompt has it.
    @Test
    func aRestartedAgentListsTheSessionAndLoadsItFromItsEntry() async throws {
        try await Self.withSupportDirectory { _, workspace in
            let sessionID = try await Self.runFirstProcess(workspace: workspace, prompt: "Remember the number 42.")

            let wire = ACPPersistenceWire()
            let backend = ACPPersistenceBackend()
            let bridge = try Self.makeBridge(wire: wire, backend: backend, workspace: workspace)
            await bridge.handleMessage(Self.listRequest(id: 1))
            let entry = try #require(Self.listedSessions(wire, id: 1)?.first)
            let listedID = try #require(entry["sessionId"]?.acpStringValue)
            let listedCwd = try #require(entry["cwd"]?.acpStringValue)
            #expect(listedID == sessionID)

            await bridge.handleMessage(Self.restoreRequest(
                "session/load",
                id: 2,
                sessionID: listedID,
                workspace: URL(fileURLWithPath: listedCwd)
            ))
            let responseIndex = try #require(wire.index(ofResponse: 2))
            #expect(wire.message(at: responseIndex)?["error"] == nil)
            #expect(wire.chunks(before: responseIndex) == [
                .init(kind: "user_message_chunk", text: "Remember the number 42."),
                .init(kind: "agent_message_chunk", text: "reply to: Remember the number 42."),
            ])
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: listedID, text: "Which number?"))
            #expect(wire.stopReason(id: 3) == "end_turn")
            let observation = try #require(await backend.observations.last)
            #expect(Self.conversation(observation.history) == [
                "user: Remember the number 42.",
                "assistant: reply to: Remember the number 42.",
            ])
            await bridge.shutdown()
        }
    }

    /// `session/list` only reads: it opens no session, writes no file, and
    /// leaves a live session as it is, which is not listed before its first
    /// turn. Like `session/delete`, it answers on a bridge that still needs
    /// the setup, which refuses `session/new`.
    @Test
    func listingCreatesNothingAndNeedsNoConfiguration() async throws {
        try await Self.withSupportDirectory { support, workspace in
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Listed", sessionID: "listed", workspace: workspace))
            _ = try TerminalSessionStore.save(Self.autosavedSession(name: "Deleted", sessionID: "deleted", workspace: workspace))

            let unconfiguredWire = ACPPersistenceWire()
            let unconfigured = try Self.makeBridge(
                wire: unconfiguredWire,
                backend: ACPPersistenceBackend(),
                workspace: workspace,
                setupRequired: true
            )
            let before = try Self.fileTree(support)
            await unconfigured.handleMessage(Self.listRequest(id: 1))
            await unconfigured.handleMessage(Self.listRequest(id: 2, params: ["cwd": workspace.path]))
            #expect(Self.listedIDs(unconfiguredWire, id: 1) == ["deleted", "listed"])
            #expect(Self.listedIDs(unconfiguredWire, id: 2) == ["deleted", "listed"])
            #expect(await unconfigured.sessionConfigurationsForTesting().isEmpty)
            #expect(try Self.fileTree(support) == before)
            await unconfigured.handleMessage(Self.deleteRequest(id: 3, sessionID: "deleted"))
            await unconfigured.handleMessage(Self.listRequest(id: 4))
            await unconfigured.handleMessage(Self.newSessionRequest(id: 5, workspace: workspace))
            #expect(unconfiguredWire.result(id: 3) == [:])
            #expect(Self.listedIDs(unconfiguredWire, id: 4) == ["listed"])
            #expect(unconfiguredWire.error(id: 5)?["code"] == .number(-32000))
            await unconfigured.shutdown()

            let wire = ACPPersistenceWire()
            let bridge = try Self.makeBridge(wire: wire, backend: ACPPersistenceBackend(), workspace: workspace)
            await bridge.handleMessage(Self.newSessionRequest(id: 1, workspace: workspace))
            let liveID = try #require(wire.sessionID(ofResponse: 1))
            let beforeListing = try Self.fileTree(support)
            await bridge.handleMessage(Self.listRequest(id: 2))
            #expect(Self.listedIDs(wire, id: 2) == ["listed"])
            #expect(await bridge.sessionConfigurationsForTesting().count == 1)
            #expect(await bridge.telegramTestConfiguration(sessionID: liveID)?.history.isEmpty == true)
            #expect(try Self.fileTree(support) == beforeListing)
            await bridge.handleMessage(Self.promptRequest(id: 3, sessionID: liveID, text: "Now listed"))
            await bridge.handleMessage(Self.listRequest(id: 4))
            #expect(Self.listedIDs(wire, id: 4) == [liveID, "listed"])
            await bridge.shutdown()
        }
    }

    /// A saved session ACP saved by itself, as the bridge writes it: marked,
    /// in the working directory `workspace` resolves to.
    private static func autosavedSession(
        name: String,
        sessionID: String,
        workspace: URL,
        savedAt: TimeInterval = 1_000
    ) -> TerminalSavedSession {
        let history = [
            AgentRuntimeMessage(role: .user, content: "Question of \(name)"),
            AgentRuntimeMessage(role: .assistant, content: "Answer of \(name)"),
        ]
        return TerminalSavedSession(
            name: name,
            sessionID: sessionID,
            cacheKey: nil,
            workingDirectoryPath: resolvedPath(workspace),
            createdAt: Date(timeIntervalSince1970: 500),
            savedAt: Date(timeIntervalSince1970: savedAt),
            modelID: plainModel.id,
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillNames: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID),
            autosaveChannel: TerminalSavedSession.acpAutosaveChannel
        )
    }

    /// The working directory a session of `workspace` is saved in, resolved
    /// as `session/new` and `session/load` resolve the `cwd`.
    private static func resolvedPath(_ workspace: URL) -> String {
        AgentConfiguration.resolvedWorkingDirectory(rawValue: workspace.path, applyLaunchDirectoryFallback: false).path
    }

    /// Creates the directory `relativePath` under `root`.
    private static func makeDirectory(_ root: URL, _ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Every file and directory under `root`, as paths relative to it.
    private static func fileTree(_ root: URL) throws -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return []
        }
        return Set(enumerator.compactMap { $0 as? String })
    }

    /// `session/list` with `params`.
    private static func listRequest(id: Int, params: [String: Any] = [:]) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": "session/list",
            "params": params,
        ]
    }

    /// The `sessions` of the reply to the `session/list` request `id`.
    private static func listedSessions(_ wire: ACPPersistenceWire, id: Int) -> [[String: JSONValue]]? {
        wire.result(id: id)?["sessions"]?.arrayValue?.compactMap(\.objectValue)
    }

    /// The `sessionId` of every session of the reply to the `session/list`
    /// request `id`, in order.
    private static func listedIDs(_ wire: ACPPersistenceWire, id: Int) -> [String]? {
        listedSessions(wire, id: id)?.compactMap { $0["sessionId"]?.acpStringValue }
    }
}
