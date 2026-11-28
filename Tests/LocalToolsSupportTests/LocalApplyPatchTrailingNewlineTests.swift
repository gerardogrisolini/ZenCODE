import Foundation
import Testing
import FeatureKit
import ToolCore
@testable import LocalToolsSupport

/// Unified-diff payloads that end with a line feed, as `git diff` output does.
/// That final line feed terminates the last patch line: it is not an empty
/// context line, so it must not be matched against the file. A bare empty line
/// before it is still an empty context line and is still validated.
///
/// Payloads are built by concatenation so their final line feed is explicit
/// (multi-line literals do not end with one).
@Suite
struct LocalApplyPatchTrailingNewlineTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ text: String, to file: URL) throws {
        try Data(text.utf8).write(to: file)
    }

    private func bytes(of file: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: file))
    }

    private func applyPatch(_ patch: String, root: URL) async throws {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == "local.applyPatch" })
        let data = try JSONSerialization.data(withJSONObject: ["patch": patch])
        _ = try await tool.invoke(inputData: data, context: FeatureContext(workingDirectory: root, environment: [:]))
    }

    /// The error description of a patch that must fail, or `nil` if it applied.
    private func failureOfApplying(_ patch: String, root: URL) async throws -> String? {
        do {
            try await applyPatch(patch, root: root)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    @Test func gitDiffEndingWithALineFeedAppliesToTheEndOfTheFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\ntwo\nthree\n", to: file)

        try await applyPatch(
            "diff --git a/f.txt b/f.txt\n"
                + "index 1111111..2222222 100644\n"
                + "--- a/f.txt\n"
                + "+++ b/f.txt\n"
                + "@@ -1,3 +1,3 @@\n"
                + " one\n"
                + "-two\n"
                + "+TWO\n"
                + " three\n",
            root: root
        )

        #expect(try String(contentsOf: file, encoding: .utf8) == "one\nTWO\nthree\n")
    }

    @Test func hunkEndingBeforeTheEndOfTheFileIgnoresTheFinalLineFeed() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("a\nb\nc\nd\n", to: file)

        try await applyPatch(
            "--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n",
            root: root
        )

        #expect(try String(contentsOf: file, encoding: .utf8) == "a\nB\nc\nd\n")
    }

    @Test func newFileDiffEndingWithALineFeedCreatesTheFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try await applyPatch(
            "--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+alpha\n+beta\n",
            root: root
        )

        let file = root.appendingPathComponent("new.txt")
        #expect(try String(contentsOf: file, encoding: .utf8) == "alpha\nbeta\n")
    }

    @Test func crlfDiffEndingWithACrlfAppliesToACrlfFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\nthree\r\n", to: file)

        try await applyPatch(
            [
                "--- a/f.txt",
                "+++ b/f.txt",
                "@@ -1,3 +1,3 @@",
                " one",
                "-two",
                "+TWO",
                " three"
            ].joined(separator: "\r\n") + "\r\n",
            root: root
        )

        #expect(try bytes(of: file) == Array("one\r\nTWO\r\nthree\r\n".utf8))
    }

    @Test func bareEmptyContextLineBeforeTheFinalLineFeedIsStillValidated() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let matching = root.appendingPathComponent("matching.txt")
        let mismatching = root.appendingPathComponent("mismatching.txt")
        try write("one\ntwo\n\nthree\n", to: matching)
        try write("one\ntwo\nthree\n", to: mismatching)

        // The bare empty line is the empty third line of the file, written
        // without its leading space; the final line feed terminates it.
        func patch(_ path: String) -> String {
            "--- a/\(path)\n+++ b/\(path)\n@@ -1,3 +1,3 @@\n one\n-two\n+TWO\n\n"
        }

        try await applyPatch(patch("matching.txt"), root: root)
        #expect(try String(contentsOf: matching, encoding: .utf8) == "one\nTWO\n\nthree\n")

        let failure = try await failureOfApplying(patch("mismatching.txt"), root: root)
        #expect(failure?.contains("Patch context mismatch in mismatching.txt at line 3") == true)
        #expect(try String(contentsOf: mismatching, encoding: .utf8) == "one\ntwo\nthree\n")
    }
}
