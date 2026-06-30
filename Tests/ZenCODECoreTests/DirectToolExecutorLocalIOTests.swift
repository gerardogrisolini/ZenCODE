//
//  DirectToolExecutorLocalIOTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//
import Foundation
@testable import ZenCODECore
import FeatureKit
import LocalToolsSupport
import Testing

@Suite
struct DirectToolExecutorLocalIOTests {
    @Test
    func baseCatalogKeepsCoreLocalAndTextToolsOnly() {
        let baseToolNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        let selectableToolNames = Set(AgentToolSelection.selectableDescriptors().map(\.name))

        #expect(baseToolNames.contains("local.exec"))
        #expect(baseToolNames.contains("local.readFile"))
        #expect(baseToolNames.contains("local.writeFile"))
        #expect(baseToolNames.contains("text.wc"))
        #expect(baseToolNames.contains("feature.list"))
        #expect(baseToolNames.contains("feature.enable"))
        #expect(baseToolNames.contains("feature.delete"))
        #expect(!baseToolNames.contains("search.glob"))
        #expect(!baseToolNames.contains("web.search"))
        #expect(!baseToolNames.contains("git.status"))

        #expect(selectableToolNames.contains("local.readFile"))
        #expect(selectableToolNames.contains("local.writeFile"))
        #expect(selectableToolNames.contains("search.glob"))
        #expect(selectableToolNames.contains("text.wc"))
        #expect(selectableToolNames.contains("web.search"))
        #expect(selectableToolNames.contains("git.status"))
        #expect(selectableToolNames.contains("git.push"))
    }

    private func runFileTool(
        _ name: String,
        arguments: [String: Any],
        workingDirectory: URL
    ) async throws -> String {
        let tool = LocalFeatureTools.fileTools().first { $0.descriptor.name == name }
        let unwrapped = try #require(tool)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await unwrapped.invoke(
            inputData: data,
            context: FeatureContext(workingDirectory: workingDirectory, environment: [:])
        )
        if let decoded = try? JSONDecoder().decode(String.self, from: output) {
            return decoded
        }
        return String(decoding: output, as: UTF8.self)
    }

    @Test
    func applyPatchUpdatesMultipleFilesAtomically() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        let fileB = root.appendingPathComponent("b.txt")
        try "line1\nline2\nline3\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "hello\nworld\n".write(to: fileB, atomically: true, encoding: .utf8)

        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         line1
        -line2
        +line2-changed
         line3
        --- a/b.txt
        +++ b/b.txt
        @@ -1,2 +1,3 @@
         hello
        +inserted
         world
        """

        let output = try await runFileTool(
            "local.applyPatch",
            arguments: ["patch": patch],
            workingDirectory: root
        )
        #expect(output.contains("2 file(s)"))
        #expect(try String(contentsOf: fileA, encoding: .utf8) == "line1\nline2-changed\nline3\n")
        #expect(try String(contentsOf: fileB, encoding: .utf8) == "hello\ninserted\nworld\n")
    }

    @Test
    func applyPatchRejectsMismatchWithoutWriting() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        try "line1\nline2\n".write(to: fileA, atomically: true, encoding: .utf8)

        let patch = """
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         WRONG
        -line2
        +line2-changed
        """

        await #expect(throws: (any Error).self) {
            _ = try await self.runFileTool(
                "local.applyPatch",
                arguments: ["patch": patch],
                workingDirectory: root
            )
        }
        #expect(try String(contentsOf: fileA, encoding: .utf8) == "line1\nline2\n")
    }

    @Test
    func applyPatchSupportsBeginPatchFormatForUpdateAddAndDelete() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-begin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.txt")
        let deleted = root.appendingPathComponent("deleted.txt")
        let added = root.appendingPathComponent("nested/added.txt")
        try "one\ntwo\nthree\n".write(to: existing, atomically: true, encoding: .utf8)
        try "remove me\n".write(to: deleted, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Update File: existing.txt
        @@
         one
        -two
        +two changed
         three
        *** Add File: nested/added.txt
        +hello
        +world
        *** Delete File: deleted.txt
        *** End Patch
        """

        let output = try await runFileTool(
            "local.applyPatch",
            arguments: ["patch": patch],
            workingDirectory: root
        )

        #expect(output.contains("3 file(s)"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "one\ntwo changed\nthree\n")
        #expect(try String(contentsOf: added, encoding: .utf8) == "hello\nworld\n")
        #expect(!FileManager.default.fileExists(atPath: deleted.path))
    }

    @Test
    func beginPatchRejectsMismatchWithoutWriting() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("applypatch-begin-mismatch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existing = root.appendingPathComponent("existing.txt")
        let added = root.appendingPathComponent("added.txt")
        try "one\ntwo\n".write(to: existing, atomically: true, encoding: .utf8)

        let patch = """
        *** Begin Patch
        *** Update File: existing.txt
        @@
         missing
        -two
        +two changed
        *** Add File: added.txt
        +must not be written
        *** End Patch
        """

        await #expect(throws: (any Error).self) {
            _ = try await self.runFileTool(
                "local.applyPatch",
                arguments: ["patch": patch],
                workingDirectory: root
            )
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "one\ntwo\n")
        #expect(!FileManager.default.fileExists(atPath: added.path))
    }

    @Test
    func readFilesReturnsEachFileWithHeader() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("readfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileA = root.appendingPathComponent("a.txt")
        let fileB = root.appendingPathComponent("b.txt")
        try "alpha\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "beta\n".write(to: fileB, atomically: true, encoding: .utf8)

        let output = try await runFileTool(
            "local.readFiles",
            arguments: ["paths": ["a.txt", "b.txt"]],
            workingDirectory: root
        )
        #expect(output.contains(fileA.path))
        #expect(output.contains(fileB.path))
        #expect(output.contains("alpha"))
        #expect(output.contains("beta"))
    }
}

private actor TestAgentRuntimeBackend: AgentRuntimeBackend {
    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        DirectAgentResponse(text: "", stopReason: "end_turn", modelID: "test")
    }
}
