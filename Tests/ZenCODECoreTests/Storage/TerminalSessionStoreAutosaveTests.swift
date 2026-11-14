//
//  TerminalSessionStoreAutosaveTests.swift
//  ZenCODE
//
//  The marker of a session a channel saved by itself
//  (`TerminalSavedSession.autosaveChannel`), a compatibility surface of the
//  saved-session format, and the lookups by session id and the listing that
//  ACP uses: they read only the header of each file and never rename,
//  migrate, or fail on a file they cannot read. Every test runs in a UUID
//  support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.serialized)
struct TerminalSessionStoreAutosaveTests {
    // MARK: - Format

    /// A session saved with a command has no marker: the key is not encoded,
    /// so such files are byte-compatible with the ones written before it.
    @Test
    func aSessionWithoutTheMarkerEncodesNoKey() throws {
        let session = Self.session(name: "manual", sessionID: "manual-id", workingDirectory: Self.workspace("Project"))

        let propertyList = try Self.propertyList(of: session)

        #expect(propertyList["autosaveChannel"] == nil)
        #expect(session.autosaveChannel == nil)
        #expect(TerminalSavedSession.currentVersion == 5)
    }

    /// A file written before the marker existed decodes with no marker.
    @Test
    func aFileWithoutTheMarkerKeyDecodesToNil() throws {
        let checkpointTree = try PropertyListSerialization.propertyList(
            from: PropertyListEncoder().encode(
                SessionCheckpointTree.fromLinearHistory([], sessionID: "legacy-id")
            ),
            format: nil
        )
        let data = try PropertyListSerialization.data(
            fromPropertyList: [
                "version": TerminalSavedSession.currentVersion,
                "name": "legacy",
                "sessionID": "legacy-id",
                "workingDirectoryPath": "/tmp/legacy-project",
                "createdAt": Date(timeIntervalSince1970: 10),
                "savedAt": Date(timeIntervalSince1970: 20),
                "selectedTools": [String](),
                "selectedSkillNames": [String](),
                "history": [Any](),
                "checkpointTree": checkpointTree,
            ] as [String: Any],
            format: .binary,
            options: 0
        )

        let decoded = try PropertyListDecoder().decode(TerminalSavedSession.self, from: data)

        #expect(decoded.name == "legacy")
        #expect(decoded.autosaveChannel == nil)
    }

    /// The marker round-trips through the store under its own key, without a
    /// version change.
    @Test
    func theMarkerRoundTrips() throws {
        try Self.withSupportDirectory { support in
            let session = Self.session(
                name: "acp",
                sessionID: "acp-id",
                workingDirectory: Self.workspace("Project"),
                autosaveChannel: TerminalSavedSession.acpAutosaveChannel
            )

            let propertyList = try Self.propertyList(of: session)
            #expect(propertyList["autosaveChannel"] as? String == "acp")
            #expect(propertyList["version"] as? Int == TerminalSavedSession.currentVersion)

            let fileURL = try TerminalSessionStore.save(session, supportDirectoryURL: support)
            let loaded = try TerminalSessionStore.load(from: fileURL)
            #expect(loaded == session)
            #expect(loaded.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)
        }
    }

    // MARK: - Lookup in a project

    /// Among the saved sessions of an id, the one ACP saved wins over a more
    /// recent one saved with a command; without it, the most recent wins.
    @Test
    func theProjectLookupPrefersTheMarkedSessionThenTheMostRecent() throws {
        try Self.withSupportDirectory { support in
            let workspace = Self.workspace("Project")
            try Self.save(
                Self.session(name: "older acp", sessionID: "shared-id", workingDirectory: workspace, savedAt: 100,
                             autosaveChannel: TerminalSavedSession.acpAutosaveChannel),
                in: support
            )
            try Self.save(
                Self.session(name: "newer manual", sessionID: "shared-id", workingDirectory: workspace, savedAt: 200),
                in: support
            )
            try Self.save(
                Self.session(name: "other", sessionID: "other-id", workingDirectory: workspace, savedAt: 300,
                             autosaveChannel: TerminalSavedSession.acpAutosaveChannel),
                in: support
            )

            let found = TerminalSessionStore.savedSession(
                sessionID: "shared-id",
                workingDirectory: workspace,
                preferringAutosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            )
            #expect(found?.name == "older acp")

            try Self.save(
                Self.session(name: "newest manual", sessionID: "manual-only", workingDirectory: workspace, savedAt: 400),
                in: support
            )
            try Self.save(
                Self.session(name: "oldest manual", sessionID: "manual-only", workingDirectory: workspace, savedAt: 50),
                in: support
            )
            let mostRecent = TerminalSessionStore.savedSession(
                sessionID: "manual-only",
                workingDirectory: workspace,
                preferringAutosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            )
            #expect(mostRecent?.name == "newest manual")
            #expect(TerminalSessionStore.savedSession(
                sessionID: "missing-id",
                workingDirectory: workspace,
                preferringAutosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            ) == nil)
        }
    }

    /// The lookup reads only what a session file can be: an unreadable file,
    /// a hidden or temporary file, and a DS4 checkpoint are skipped without
    /// failing, and a session file with a name that is not its current one
    /// is found where it is, renamed by nothing.
    @Test
    func theLookupIgnoresWhatIsNotASessionAndRenamesNothing() throws {
        try Self.withSupportDirectory { support in
            let workspace = Self.workspace("Project")
            let directory = TerminalSessionStore.sessionsDirectoryURL(for: workspace, supportDirectoryURL: support)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let valid = Self.session(
                name: "valid",
                sessionID: "probe-id",
                workingDirectory: workspace,
                autosaveChannel: TerminalSavedSession.acpAutosaveChannel
            )
            let encoded = try Self.binary(valid)
            // Everything but `legacy.session` holds a session the lookup must not read.
            try Data("not a property list".utf8).write(to: directory.appendingPathComponent("broken.session"))
            try encoded.write(to: directory.appendingPathComponent(".hidden.session"))
            try encoded.write(to: directory.appendingPathComponent("pending.session.tmp"))
            try encoded.write(to: directory.appendingPathComponent("valid.ds4kv"))
            try encoded.write(to: directory.appendingPathComponent("valid.ds4kv.tmp.1"))
            let legacyURL = directory.appendingPathComponent("legacy.session")
            try encoded.write(to: legacyURL)
            let before = try Set(FileManager.default.contentsOfDirectory(atPath: directory.path))

            let files = TerminalSessionStore.savedSessionFiles(in: directory)
            #expect(files.map(\.url.lastPathComponent) == ["legacy.session"])
            #expect(files.first?.header.sessionID == "probe-id")
            #expect(files.first?.header.autosaveChannel == TerminalSavedSession.acpAutosaveChannel)

            let found = TerminalSessionStore.savedSession(
                sessionID: "probe-id",
                workingDirectory: workspace,
                preferringAutosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            )
            #expect(found == valid)
            let everywhere = TerminalSessionStore.autosavedSessionFiles(
                sessionID: "probe-id",
                autosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            )
            #expect(everywhere.map(\.url.lastPathComponent) == ["legacy.session"])

            // Nothing was renamed, moved, or migrated.
            #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == before)
            #expect(!FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(TerminalSessionStore.filename(for: "valid")).path
            ))
        }
    }

    // MARK: - Lookup in every project

    /// The sessions of an id that ACP saved are found in every project; the
    /// ones saved with a command and those of other ids are not.
    @Test
    func theAutosavedLookupSearchesEveryProject() throws {
        try Self.withSupportDirectory { support in
            let first = Self.workspace("First")
            let second = Self.workspace("Second")
            let acp = TerminalSavedSession.acpAutosaveChannel
            try Self.save(Self.session(name: "a", sessionID: "id", workingDirectory: first, autosaveChannel: acp), in: support)
            try Self.save(Self.session(name: "b", sessionID: "id", workingDirectory: second, autosaveChannel: acp), in: support)
            try Self.save(Self.session(name: "c", sessionID: "id", workingDirectory: second), in: support)
            try Self.save(Self.session(name: "d", sessionID: "other", workingDirectory: first, autosaveChannel: acp), in: support)

            let files = TerminalSessionStore.autosavedSessionFiles(
                sessionID: "id",
                autosaveChannel: acp,
                supportDirectoryURL: support
            )

            #expect(Set(files.map(\.header.name)) == ["a", "b"])
            #expect(TerminalSessionStore.autosavedSessionFiles(
                sessionID: "missing",
                autosaveChannel: acp,
                supportDirectoryURL: support
            ).isEmpty)
        }
    }

    /// The listing of what a channel saved: in a project, only the sessions
    /// saved in exactly that working directory, not those of another folder
    /// with the same name in the same project directory; in every project,
    /// each session only in the directory of its own project. Sessions saved
    /// with a command or by another channel are never included.
    @Test
    func theAutosavedListingMatchesTheExactWorkingDirectoryOrEveryProject() throws {
        try Self.withSupportDirectory { support in
            let first = Self.workspace("Same")
            let second = Self.workspace("Same")
            let other = Self.workspace("Other")
            let acp = TerminalSavedSession.acpAutosaveChannel
            try Self.save(Self.session(name: "first", sessionID: "first", workingDirectory: first, autosaveChannel: acp), in: support)
            try Self.save(Self.session(name: "second", sessionID: "second", workingDirectory: second, autosaveChannel: acp), in: support)
            try Self.save(Self.session(name: "other", sessionID: "other", workingDirectory: other, autosaveChannel: acp), in: support)
            try Self.save(Self.session(name: "manual", sessionID: "manual", workingDirectory: first), in: support)
            try Self.save(
                Self.session(name: "telegram", sessionID: "telegram", workingDirectory: first, autosaveChannel: "telegram"),
                in: support
            )
            // A session of `other` copied into the directory of `Same`.
            let otherDirectory = TerminalSessionStore.sessionsDirectoryURL(for: other, supportDirectoryURL: support)
            let sameDirectory = TerminalSessionStore.sessionsDirectoryURL(for: first, supportDirectoryURL: support)
            #expect(sameDirectory == TerminalSessionStore.sessionsDirectoryURL(for: second, supportDirectoryURL: support))
            try FileManager.default.copyItem(
                at: otherDirectory.appendingPathComponent(TerminalSessionStore.filename(for: "other")),
                to: sameDirectory.appendingPathComponent("misplaced.session")
            )

            func names(in workingDirectory: URL?) -> [String] {
                TerminalSessionStore.autosavedSessionFiles(
                    autosaveChannel: acp,
                    workingDirectory: workingDirectory,
                    supportDirectoryURL: support
                ).map(\.header.name).sorted()
            }

            #expect(names(in: first) == ["first"])
            #expect(names(in: second) == ["second"])
            #expect(names(in: URL(fileURLWithPath: second.path + "/./")) == ["second"])
            #expect(names(in: other) == ["other"])
            #expect(names(in: Self.workspace("Same")) == [])
            #expect(names(in: nil) == ["first", "other", "second"])
        }
    }

    /// Deleting a file found by id removes it with its DS4 checkpoint.
    @Test
    func deletingAFoundFileRemovesItsCheckpointToo() throws {
        try Self.withSupportDirectory { support in
            let workspace = Self.workspace("Project")
            let session = Self.session(
                name: "with checkpoint",
                sessionID: "checkpoint-id",
                workingDirectory: workspace,
                autosaveChannel: TerminalSavedSession.acpAutosaveChannel
            )
            let fileURL = try TerminalSessionStore.save(session, supportDirectoryURL: support)
            let checkpointURL = TerminalSessionStore.engineCheckpointURL(
                name: session.name,
                workingDirectory: workspace,
                supportDirectoryURL: support
            )
            try Data("kv".utf8).write(to: checkpointURL)
            let file = try #require(TerminalSessionStore.autosavedSessionFiles(
                sessionID: "checkpoint-id",
                autosaveChannel: TerminalSavedSession.acpAutosaveChannel,
                supportDirectoryURL: support
            ).first)

            #expect(try TerminalSessionStore.deleteSavedSessionFile(file))

            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
            #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
            #expect(try TerminalSessionStore.deleteSavedSessionFile(file) == false)
        }
    }

    // MARK: - Fixtures

    private static func withSupportDirectory(_ body: (URL) throws -> Void) throws {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-session-autosave-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        try AppStorageDirectory.withSupportDirectoryURL(support) {
            try body(support)
        }
    }

    /// A working directory path named `name`; nothing is created there.
    private static func workspace(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("autosave-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    private static func session(
        name: String,
        sessionID: String,
        workingDirectory: URL,
        savedAt: TimeInterval = 20,
        autosaveChannel: String? = nil
    ) -> TerminalSavedSession {
        let history = [
            AgentRuntimeMessage(role: .user, content: "Question of \(name)"),
            AgentRuntimeMessage(role: .assistant, content: "Answer of \(name)"),
        ]
        return TerminalSavedSession(
            name: name,
            sessionID: sessionID,
            cacheKey: nil,
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: savedAt),
            modelID: "model",
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillNames: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID),
            autosaveChannel: autosaveChannel
        )
    }

    private static func save(_ session: TerminalSavedSession, in support: URL) throws {
        _ = try TerminalSessionStore.save(session, supportDirectoryURL: support)
    }

    private static func binary(_ session: TerminalSavedSession) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(session)
    }

    private static func propertyList(of session: TerminalSavedSession) throws -> [String: Any] {
        try #require(
            try PropertyListSerialization.propertyList(
                from: PropertyListEncoder().encode(session),
                format: nil
            ) as? [String: Any]
        )
    }
}
