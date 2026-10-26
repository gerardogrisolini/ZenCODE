import Foundation
import Testing
import FeatureKit
import ToolCore
@testable import LocalToolsSupport

extension LocalToolsSerialGroup {
/// Unified-diff payloads whose hunk bodies hold lines that look like file
/// headers: removing `-- note` yields `--- note`, adding `++ x` yields `+++ x`.
@Suite(.serialized)
struct LocalApplyPatchHeaderLookalikeTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func applyPatch(_ patch: String, root: URL) async throws {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == "local.applyPatch" })
        let data = try JSONSerialization.data(withJSONObject: ["patch": patch])
        _ = try await tool.invoke(inputData: data, context: FeatureContext(workingDirectory: root, environment: [:]))
    }

    @Test func removedDashCommentFollowedByPlainAdditionIsApplied() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("schema.sql")
        try "-- old comment\nselect 1;\n".write(to: file, atomically: true, encoding: .utf8)

        try await applyPatch("""
        --- a/schema.sql
        +++ b/schema.sql
        @@ -1,2 +1,2 @@
        --- old comment
        +select 0;
         select 1;
        """, root: root)

        #expect(try String(contentsOf: file, encoding: .utf8) == "select 0;\nselect 1;\n")
    }

    @Test func removedAndAddedHeaderLookalikesStayInTheirHunk() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("schema.sql")
        try "select 1;\n-- old comment\nselect 2;\n".write(to: file, atomically: true, encoding: .utf8)

        try await applyPatch("""
        diff --git a/schema.sql b/schema.sql
        --- a/schema.sql
        +++ b/schema.sql
        @@ -1,3 +1,3 @@
         select 1;
        --- old comment
        +++ new counter
         select 2;
        """, root: root)

        #expect(try String(contentsOf: file, encoding: .utf8) == "select 1;\n++ new counter\nselect 2;\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("new counter").path))
    }

    @Test func headerLookalikesInOneFileDoNotHideTheNextFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.lua")
        let second = root.appendingPathComponent("two.txt")
        try "-- a\n-- b\nkeep\n".write(to: first, atomically: true, encoding: .utf8)
        try "old\n".write(to: second, atomically: true, encoding: .utf8)

        // Bare `@@` hunks, as language models often write them.
        try await applyPatch("""
        --- a/one.lua
        +++ b/one.lua
        @@
        --- a
        --- b
        +++ c
         keep
        --- a/two.txt
        +++ b/two.txt
        @@
        -old
        +new
        """, root: root)

        #expect(try String(contentsOf: first, encoding: .utf8) == "++ c\nkeep\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "new\n")
    }

    @Test func gitStylePatchWithCountedHunksKeepsLookalikesInTheirHunkAndCreatesNoStrayFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.lua")
        let second = root.appendingPathComponent("two.txt")
        try "keep\n-- x\n".write(to: first, atomically: true, encoding: .utf8)
        try "old\n".write(to: second, atomically: true, encoding: .utf8)

        // The removed `-- x` and the added `++ y` are the last two lines of the
        // first hunk, whose counts are exact, right before the second file.
        try await applyPatch("""
        diff --git a/one.lua b/one.lua
        index 1111111..2222222 100644
        --- a/one.lua
        +++ b/one.lua
        @@ -1,2 +1,2 @@
         keep
        --- x
        +++ y
        diff --git a/two.txt b/two.txt
        index 3333333..4444444 100644
        --- a/two.txt
        +++ b/two.txt
        @@ -1 +1 @@
        -old
        +new
        """, root: root)

        #expect(try String(contentsOf: first, encoding: .utf8) == "keep\n++ y\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "new\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(entries == ["one.lua", "two.txt"])
    }

    @Test func trulyMalformedHeaderWithoutNewFileLineStillFailsAndWritesNothing() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = root.appendingPathComponent("x.txt")
        let other = root.appendingPathComponent("y.txt")
        try "old\n".write(to: broken, atomically: true, encoding: .utf8)
        try "keep\n".write(to: other, atomically: true, encoding: .utf8)

        do {
            try await applyPatch("""
            --- a/x.txt
            @@ -1 +1 @@
            -old
            +new
            --- a/y.txt
            +++ b/y.txt
            @@ -1 +1 @@
            -keep
            +changed
            """, root: root)
            Issue.record("A header without a +++ line unexpectedly succeeded")
        } catch {
            #expect(error.localizedDescription.contains("missing +++ header"))
        }

        #expect(try String(contentsOf: broken, encoding: .utf8) == "old\n")
        #expect(try String(contentsOf: other, encoding: .utf8) == "keep\n")
        let entries = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        #expect(entries == ["x.txt", "y.txt"])
    }

    @Test func ordinaryMultiFileUnifiedDiffIsUnchanged() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.txt")
        let second = root.appendingPathComponent("b.txt")
        try "line1\nline2\n".write(to: first, atomically: true, encoding: .utf8)
        try "hello\n".write(to: second, atomically: true, encoding: .utf8)

        try await applyPatch("""
        --- a/a.txt
        +++ b/a.txt
        @@ -1,2 +1,2 @@
         line1
        -line2
        +line2-changed
        --- a/b.txt
        +++ b/b.txt
        @@ -1 +1,2 @@
         hello
        +world
        """, root: root)

        #expect(try String(contentsOf: first, encoding: .utf8) == "line1\nline2-changed\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "hello\nworld\n")
    }
}
}
