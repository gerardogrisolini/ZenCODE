import Foundation
import Testing
import FeatureKit
import LocalToolsSupport

@Suite
struct LocalFileEditTests {
    @Test
    func editSchemasAreCanonicalCompactAndNestedRequirementsAreExplicit() throws {
        let edit = try Self.descriptor("local.editFile")
        let replace = try Self.descriptor("local.replace")
        let multi = try Self.descriptor("local.multiEdit")

        for descriptor in [edit, replace] {
            let schema = try Self.schema(descriptor.inputSchema)
            let properties = try #require(schema["properties"] as? [String: Any])
            #expect(Set(properties.keys) == ["path", "old", "new"])
            #expect(schema["required"] as? [String] == ["path", "old", "new"])
        }

        let multiSchema = try Self.schema(multi.inputSchema)
        let multiProperties = try #require(multiSchema["properties"] as? [String: Any])
        #expect(Set(multiProperties.keys) == ["path", "edits"])
        #expect(multiSchema["required"] as? [String] == ["path", "edits"])
        let edits = try #require(multiProperties["edits"] as? [String: Any])
        let item = try #require(edits["items"] as? [String: Any])
        let itemProperties = try #require(item["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == ["old", "new"])
        #expect(item["required"] as? [String] == ["old", "new"])

        // Baseline before this migration: editFile 318, multiEdit 368, replace 253 bytes.
        #expect(edit.inputSchema.utf8.count <= 170)
        #expect(multi.inputSchema.utf8.count <= 240)
        #expect(replace.inputSchema.utf8.count <= 170)
        #expect(
            Double(edit.inputSchema.utf8.count + multi.inputSchema.utf8.count + replace.inputSchema.utf8.count)
                <= 0.6 * Double(318 + 368 + 253)
        )
    }

    @Test
    func fiveEditsUseLessArgumentPayloadThanFiveCalls() throws {
        let edits = (0..<5).map { index in
            ["old": "let value\(index) = \(index)", "new": "let value\(index) = \(index + 1)"]
        }
        let calls = edits.map { edit in
            ["path": "Sources/App.swift", "old": edit["old"]!, "new": edit["new"]!]
        }
        let fiveBytes = try calls.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]).count
        }.reduce(0, +)
        let multiBytes = try JSONSerialization.data(
            withJSONObject: ["path": "Sources/App.swift", "edits": edits],
            options: [.sortedKeys]
        ).count
        #expect(multiBytes < fiveBytes)
    }

    @Test
    func uniqueReplacementInsertionDeletionUnicodeAndExactWhitespace() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.txt")
        try "α\n\tlet value = 1\nomega".write(to: file, atomically: true, encoding: .utf8)

        _ = try await Self.invoke("local.editFile", [
            "path": file.path,
            "old": "\tlet value = 1",
            "new": "\tlet value = 1\n\tlet café = true"
        ], root)
        _ = try await Self.invoke("local.editFile", [
            "path": file.path,
            "old": "α\n",
            "new": ""
        ], root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "\tlet value = 1\n\tlet café = true\nomega")
    }

    @Test(arguments: ["\n", "\r\n", "\r"])
    func uniformLineEndingsAdaptReadFileStyleOldAndNew(_ separator: String) async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("endings.txt")
        try "one\(separator)two\(separator)three".write(to: file, atomically: true, encoding: .utf8)

        _ = try await Self.invoke("local.editFile", [
            "path": file.path,
            "old": "one\ntwo",
            "new": "ONE\nTWO\nEXTRA"
        ], root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "ONE\(separator)TWO\(separator)EXTRA\(separator)three")
    }

    @Test
    func singleLineAnchorAdaptsInsertedNewlinesAndPreservesMissingFinalNewline() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("crlf.txt")
        try "one\r\ntwo".write(to: file, atomically: true, encoding: .utf8)
        _ = try await Self.invoke("local.editFile", [
            "path": file.path, "old": "two", "new": "two\nthree"
        ], root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "one\r\ntwo\r\nthree")
    }

    @Test
    func mixedLineEndingsRequireAnExactMatch() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("mixed.txt")
        let original = "one\r\ntwo\nthree"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let error = await Self.failure("local.editFile", [
            "path": file.path, "old": "one\ntwo", "new": "changed"
        ], root)
        #expect(error.contains("old text was not found"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test
    func absentAmbiguousOverlappingAndEmptyMatchesFailWithoutEchoingOld() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ambiguous.txt")
        try "aaaa secret-value".write(to: file, atomically: true, encoding: .utf8)

        let absent = await Self.failure("local.editFile", [
            "path": file.path, "old": "very-long-secret-old-value", "new": "x"
        ], root)
        #expect(absent.contains("old text was not found"))
        #expect(!absent.contains("very-long-secret-old-value"))

        let overlapping = await Self.failure("local.editFile", [
            "path": file.path, "old": "aa", "new": "x"
        ], root)
        #expect(overlapping.contains("matched 3 times"))

        let empty = await Self.failure("local.editFile", [
            "path": file.path, "old": "", "new": "x"
        ], root)
        #expect(empty.contains("must not be empty"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "aaaa secret-value")
    }

    @Test
    func multiEditIsOrderedAtomicAndCanEditEarlierOutput() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("ordered.txt")
        try "alpha beta gamma".write(to: file, atomically: true, encoding: .utf8)

        _ = try await Self.invoke("local.multiEdit", [
            "path": file.path,
            "edits": [
                ["old": "beta", "new": "BETA plus"],
                ["old": "BETA plus", "new": "final"]
            ]
        ], root)
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha final gamma")
    }

    @Test
    func multiEditMiddleFailureLeavesFileUntouchedAndReportsOneBasedIndex() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("atomic.txt")
        let original = "alpha\nbeta\ngamma\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let error = await Self.failure("local.multiEdit", [
            "path": file.path,
            "edits": [
                ["old": "alpha", "new": "A"],
                ["old": "missing", "new": "M"],
                ["old": "gamma", "new": "G"]
            ]
        ], root)
        #expect(error.contains("edit 2 of 3"))
        #expect(error.contains("No changes were written"))
        #expect(!error.contains("missing"))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test
    func multiEditRejectsEmptyArrayAndMissingNestedValues() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("empty.txt")
        try "value".write(to: file, atomically: true, encoding: .utf8)

        let empty = await Self.failure("local.multiEdit", ["path": file.path, "edits": []], root)
        #expect(empty.contains("No changes were written"))
        let missing = await Self.failure("local.multiEdit", [
            "path": file.path, "edits": [["old": "value"]]
        ], root)
        #expect(missing.contains("No changes were written"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "value")
    }

    @Test
    func multilineFeedbackUsesHeadTailOmissionWithinBudget() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("multiline.txt")
        let originalLines = (1...50).map { "old line \($0)" }
        try originalLines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let replacement = (1...40).map { "new line \($0) " + String(repeating: "y", count: 120) }
            .joined(separator: "\n")

        let output = try await Self.invoke("local.editFile", [
            "path": file.path,
            "old": originalLines[9...39].joined(separator: "\n"),
            "new": replacement
        ], root)
        #expect(output.components(separatedBy: "\n").count <= 16)
        #expect(output.utf8.count <= 3_072)
        #expect(output.contains("omitted"))
    }

    @Test
    func feedbackMergesWindowsAndHonorsLineAndByteBudgets() async throws {
        let root = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        let lines = (1...80).map { "line \($0) " + String(repeating: "x", count: 300) }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

        let single = try await Self.invoke("local.editFile", [
            "path": file.path, "old": "line 40 "+String(repeating: "x", count: 300), "new": "changed"
        ], root)
        #expect(single.components(separatedBy: "\n").count <= 8)
        #expect(single.utf8.count <= 2_048)

        let multi = try await Self.invoke("local.multiEdit", [
            "path": file.path,
            "edits": [
                ["old": "line 41 "+String(repeating: "x", count: 300), "new": "forty-one"],
                ["old": "line 42 "+String(repeating: "x", count: 300), "new": "forty-two"],
                ["old": "line 70 "+String(repeating: "x", count: 300), "new": "seventy"]
            ]
        ], root)
        #expect(multi.components(separatedBy: "\n").count <= 24)
        #expect(multi.utf8.count <= 4_096)
        #expect(multi.components(separatedBy: "Current file around edits").count - 1 == 1)
        #expect(multi.contains("omitted"))
    }

    private static func descriptor(_ name: String) throws -> FeatureToolDescriptor {
        try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == name }?.descriptor)
    }

    private static func schema(_ value: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any])
    }

    private static func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func invoke(_ name: String, _ arguments: [String: Any], _ root: URL) async throws -> String {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == name })
        let output = try await tool.invoke(
            inputData: try JSONSerialization.data(withJSONObject: arguments),
            context: FeatureContext(workingDirectory: root, environment: [:])
        )
        return (try? JSONDecoder().decode(String.self, from: output)) ?? String(decoding: output, as: UTF8.self)
    }

    private static func failure(_ name: String, _ arguments: [String: Any], _ root: URL) async -> String {
        do {
            _ = try await invoke(name, arguments, root)
            return ""
        } catch {
            return String(describing: error)
        }
    }
}
