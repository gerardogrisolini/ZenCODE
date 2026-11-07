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
}
}
