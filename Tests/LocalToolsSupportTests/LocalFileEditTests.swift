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

        // Compact UTF-8 schemas measured in Docs/editing-tool-size-baseline.md.
        #expect(edit.inputSchema.utf8.count == 137)
        #expect(multi.inputSchema.utf8.count == 224)
        #expect(replace.inputSchema.utf8.count == 137)
        #expect(edit.inputSchema.utf8.count + multi.inputSchema.utf8.count + replace.inputSchema.utf8.count == 498)
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
