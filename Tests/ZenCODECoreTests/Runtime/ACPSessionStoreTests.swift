//
//  ACPSessionStoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//

import Foundation
import Testing
@testable import ZenCODECore

/// The records ``ACPSessionStore`` keeps for the ACP sessions: one binary
/// property list per session, under the project key, named by the hash of
/// the session id, private to the user, and read leniently. Every test runs
/// in its own UUID support directory, passed to the store.
struct ACPSessionStoreTests {
    @Test
    func aSavedRecordLoadsBackUnderTheProjectKeyAndTheHashOfItsID() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let record = Self.record(sessionID: "acp-store-round-trip", workspace: workspace)

            let written = try store.save(record)

            #expect(written == record)
            #expect(store.load(sessionID: record.sessionID, workingDirectory: workspace) == record)
            let fileURL = store.sessionFileURL(sessionID: record.sessionID, workingDirectory: workspace)
            #expect(fileURL.standardizedFileURL == support
                .appendingPathComponent("acp-sessions", isDirectory: true)
                .appendingPathComponent(TerminalSessionStore.projectKey(for: workspace), isDirectory: true)
                .appendingPathComponent("\(Data(record.sessionID.utf8).sha256Hex()).plist")
                .standardizedFileURL)
            // A binary property list.
            let data = try Data(contentsOf: fileURL)
            #expect(data.starts(with: Array("bplist".utf8)))
        }
    }

    @Test
    func aSessionWithoutARecordLoadsNil() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            #expect(store.load(sessionID: "acp-store-missing", workingDirectory: workspace) == nil)
            try store.save(Self.record(sessionID: "acp-store-other", workspace: workspace))
            #expect(store.load(sessionID: "acp-store-missing", workingDirectory: workspace) == nil)
        }
    }

    @Test
    func aCorruptedRecordLoadsNil() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let sessionID = "acp-store-corrupted"
            let fileURL = store.sessionFileURL(sessionID: sessionID, workingDirectory: workspace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("not a property list".utf8).write(to: fileURL)

            #expect(store.load(sessionID: sessionID, workingDirectory: workspace) == nil)
        }
    }

    @Test
    func aRecordOfAnUnknownVersionLoadsNil() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let sessionID = "acp-store-future"
            let future = Self.record(sessionID: sessionID, workspace: workspace, version: 2)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let fileURL = store.sessionFileURL(sessionID: sessionID, workingDirectory: workspace)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(future).write(to: fileURL)

            #expect(store.load(sessionID: sessionID, workingDirectory: workspace) == nil)
        }
    }

    @Test
    func aRecordOfAnotherSessionLoadsNil() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let saved = try store.save(Self.record(sessionID: "acp-store-owner", workspace: workspace))
            let otherURL = store.sessionFileURL(sessionID: "acp-store-intruder", workingDirectory: workspace)
            try FileManager.default.copyItem(
                at: store.sessionFileURL(sessionID: saved.sessionID, workingDirectory: workspace),
                to: otherURL
            )

            #expect(store.load(sessionID: "acp-store-intruder", workingDirectory: workspace) == nil)
            #expect(store.load(sessionID: saved.sessionID, workingDirectory: workspace) == saved)
        }
    }

    @Test(arguments: ["../../escaped", "nested/session", "/absolute/session", "..", "."])
    func anIDWithPathSeparatorsStaysInsideTheProjectDirectory(sessionID: String) throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let projectDirectory = store.sessionsDirectoryURL(workingDirectory: workspace)
            let record = Self.record(sessionID: sessionID, workspace: workspace)

            try store.save(record)

            let fileURL = store.sessionFileURL(sessionID: sessionID, workingDirectory: workspace)
            #expect(fileURL.deletingLastPathComponent().standardizedFileURL == projectDirectory.standardizedFileURL)
            #expect(fileURL.lastPathComponent == "\(Data(sessionID.utf8).sha256Hex()).plist")
            #expect(try FileManager.default.contentsOfDirectory(atPath: projectDirectory.path)
                == [fileURL.lastPathComponent])
            // Nothing else was created in the support directory.
            #expect(try FileManager.default.contentsOfDirectory(atPath: support.path) == ["acp-sessions"])
            #expect(store.load(sessionID: sessionID, workingDirectory: workspace) == record)
        }
    }

    @Test
    func aRecordIsPrivateToTheUser() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let record = Self.record(sessionID: "acp-store-private", workspace: workspace)

            try store.save(record)

            let fileURL = store.sessionFileURL(sessionID: record.sessionID, workingDirectory: workspace)
            #expect(try Self.posixMode(of: fileURL) == 0o600)
            #expect(try Self.posixMode(of: fileURL.deletingLastPathComponent()) == 0o700)
        }
    }

    @Test
    func aLaterSaveKeepsTheCreationDate() throws {
        try Self.withSandbox { support, workspace in
            let store = ACPSessionStore(supportDirectoryURL: support)
            let sessionID = "acp-store-created"
            let first = Self.record(
                sessionID: sessionID,
                workspace: workspace,
                date: Date(timeIntervalSince1970: 1_000),
                history: [AgentRuntimeMessage(role: .user, content: "first")]
            )
            let second = Self.record(
                sessionID: sessionID,
                workspace: workspace,
                date: Date(timeIntervalSince1970: 2_000),
                history: [
                    AgentRuntimeMessage(role: .user, content: "first"),
                    AgentRuntimeMessage(role: .assistant, content: "second"),
                ]
            )

            try store.save(first)
            let written = try store.save(second)

            let loaded = try #require(store.load(sessionID: sessionID, workingDirectory: workspace))
            #expect(loaded == written)
            #expect(loaded.createdAt == Date(timeIntervalSince1970: 1_000))
            #expect(loaded.savedAt == Date(timeIntervalSince1970: 2_000))
            #expect(loaded.history == second.history)
        }
    }

    // MARK: - Fixture

    private static func record(
        sessionID: String,
        workspace: URL,
        version: Int = ACPSavedSession.currentVersion,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000),
        history: [AgentRuntimeMessage] = [
            AgentRuntimeMessage(role: .user, content: "What is in the parser?"),
            AgentRuntimeMessage(role: .assistant, content: "A tokenizer.", reasoningContent: "Read it."),
        ]
    ) -> ACPSavedSession {
        ACPSavedSession(
            version: version,
            sessionID: sessionID,
            workingDirectoryPath: workspace.path,
            createdAt: date,
            savedAt: date,
            modelID: "test-model",
            agentID: "developer",
            thinkingSelection: AgentThinkingSelection.high.rawValue,
            preserveThinking: true,
            history: history
        )
    }

    /// Runs `body` with a support directory and a workspace in a UUID
    /// directory, removed afterwards.
    private static func withSandbox(_ body: (_ support: URL, _ workspace: URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-session-store-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(support, workspace)
    }

    private static func posixMode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
