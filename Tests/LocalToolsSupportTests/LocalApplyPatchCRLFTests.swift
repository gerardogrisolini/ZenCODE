import Foundation
import Testing
import FeatureKit
import ToolCore
@testable import LocalToolsSupport

extension LocalToolsSerialGroup {
/// `local.applyPatch` with CRLF payloads. Line content is byte-exact: a CRLF
/// patch applies to a CRLF file and keeps it CRLF, while an LF patch does not
/// match a CRLF file (and the reverse). Only structure is CR-tolerant: the
/// `*** Begin Patch` / `*** End Patch` markers, `--- ` / `+++ ` header paths,
/// `\ No newline at end of file`, and blank hunk lines.
///
/// Payloads are built from explicit line arrays joined with `"\r\n"` (never
/// multi-line literals, whose line endings are the source file's). The last
/// element of a joined payload has no `\r`, so unified-diff payloads end with a
/// `\ No newline at end of file` marker, which is skipped, instead of a
/// content line.
@Suite(.serialized)
struct LocalApplyPatchCRLFTests {
    private static let noNewlineMarker = "\\ No newline at end of file"

    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func crlf(_ lines: [String]) -> String {
        lines.joined(separator: "\r\n")
    }

    private func lf(_ lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    private func bytes(_ text: String) -> [UInt8] {
        Array(text.utf8)
    }

    private func bytes(of file: URL) throws -> [UInt8] {
        Array(try Data(contentsOf: file))
    }

    private func entries(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: file)
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

    private func describe(_ line: LocalToolsSupport.DiffLine) -> String {
        switch line {
        case let .context(text): "context:\(text)"
        case let .removed(text): "removed:\(text)"
        case let .added(text): "added:\(text)"
        }
    }

    // MARK: - Unified diff

    @Test func crlfUnifiedDiffAppliesToACrlfFileAndKeepsItCrlf() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\nthree\r\n", to: file)

        try await applyPatch(crlf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,3 +1,4 @@",
            " one",
            "-two",
            "+TWO",
            " three",
            "+four",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try bytes(of: file) == bytes("one\r\nTWO\r\nthree\r\nfour\r\n"))
        #expect(try entries(in: root) == ["f.txt"])
    }

    @Test func crlfUnifiedDiffWithGitHeadersTargetsTheRealFileName() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\n", to: file)

        try await applyPatch(crlf([
            "diff --git a/f.txt b/f.txt",
            "index 1111111..2222222 100644",
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,2 +1,2 @@",
            " one",
            "-two",
            "+TWO",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try bytes(of: file) == bytes("one\r\nTWO\r\n"))
        #expect(try entries(in: root) == ["f.txt"])
    }

    @Test func crlfUnifiedDiffCreatesANewFileFromDevNullWithCrlfContent() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        try await applyPatch(crlf([
            "--- /dev/null",
            "+++ b/new.txt",
            "@@ -0,0 +1,2 @@",
            "+alpha",
            "+beta",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try bytes(of: root.appendingPathComponent("new.txt")) == bytes("alpha\r\nbeta\r\n"))
        #expect(try entries(in: root) == ["new.txt"])
    }

    @Test func crlfUnifiedDiffDeletesAFileWithoutACarriageReturnInTheTarget() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("gone.txt")
        try write("one\r\ntwo\r\n", to: file)
        try write("keep\r\n", to: root.appendingPathComponent("keep.txt"))

        try await applyPatch(crlf([
            "--- a/gone.txt",
            "+++ /dev/null",
            "@@ -1,2 +0,0 @@",
            "-one",
            "-two",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try entries(in: root) == ["keep.txt"])
        #expect(try bytes(of: root.appendingPathComponent("keep.txt")) == bytes("keep\r\n"))
    }

    @Test func blankCrlfContextLineAndNoNewlineMarkerAreRecognized() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\n\r\ntwo\r\nthree\r\n", to: file)

        // The empty line of a CRLF file is the bare line `\r` in the patch; the
        // first marker ends in `\r`, the last one (the end of the payload) does not.
        try await applyPatch(crlf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,4 +1,4 @@",
            " one",
            "",
            "-two",
            "+TWO",
            Self.noNewlineMarker,
            " three",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try bytes(of: file) == bytes("one\r\n\r\nTWO\r\nthree\r\n"))
    }

    @Test func crlfMultiFileUnifiedDiffKeepsHeaderLookalikesInTheirHunk() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("one.sql")
        let second = root.appendingPathComponent("two.txt")
        try write("select 1;\r\n-- old comment\r\nselect 2;\r\n", to: first)
        try write("old\r\n", to: second)

        // Removing `-- old comment` and adding `++ new counter` yields lines that
        // look like file headers; the CRLF payload must treat them as content.
        try await applyPatch(crlf([
            "diff --git a/one.sql b/one.sql",
            "--- a/one.sql",
            "+++ b/one.sql",
            "@@ -1,3 +1,3 @@",
            " select 1;",
            "--- old comment",
            "+++ new counter",
            " select 2;",
            "diff --git a/two.txt b/two.txt",
            "--- a/two.txt",
            "+++ b/two.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            Self.noNewlineMarker
        ]), root: root)

        #expect(try bytes(of: first) == bytes("select 1;\r\n++ new counter\r\nselect 2;\r\n"))
        #expect(try bytes(of: second) == bytes("new\r\n"))
        #expect(try entries(in: root) == ["one.sql", "two.txt"])
    }

    // MARK: - Unified diff parsing

    @Test func crlfHeadersDoNotKeepTheCarriageReturnInThePath() throws {
        let patches = try LocalToolsSupport.parseUnifiedDiff(crlf([
            "--- a/changed.txt",
            "+++ b/changed.txt",
            "@@ -1 +1 @@",
            "-a",
            "+b",
            "--- /dev/null",
            "+++ b/added.txt",
            "@@ -0,0 +1 @@",
            "+c",
            "--- a/removed.txt",
            "+++ /dev/null",
            "@@ -1 +0,0 @@",
            "-d",
            Self.noNewlineMarker
        ]))

        #expect(patches.map(\.path) == ["changed.txt", "added.txt", "removed.txt"])
        #expect(patches.map(\.isNewFile) == [false, true, false])
        #expect(patches.map(\.isDeletedFile) == [false, false, true])
    }

    @Test func crlfHunkLinesKeepTheirCarriageReturnAndBlankLinesStayContext() throws {
        let patches = try LocalToolsSupport.parseUnifiedDiff(crlf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,3 +1,3 @@",
            " one",
            "",
            "-two",
            Self.noNewlineMarker,
            "+TWO",
            Self.noNewlineMarker
        ]))

        let hunk = try #require(patches.first?.hunks.first)
        #expect(patches.count == 1)
        #expect(hunk.lines.map(describe) == [
            "context:one\r",
            "context:\r",
            "removed:two\r",
            "added:TWO\r"
        ])
    }

    @Test func aBareEmptyLfHunkLineIsStillAnEmptyContextLine() throws {
        let patches = try LocalToolsSupport.parseUnifiedDiff(lf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,3 +1,3 @@",
            " one",
            "",
            "-two",
            Self.noNewlineMarker,
            "+TWO"
        ]))

        let hunk = try #require(patches.first?.hunks.first)
        #expect(hunk.lines.map(describe) == ["context:one", "context:", "removed:two", "added:TWO"])
    }

    // MARK: - Begin Patch

    @Test func isBeginPatchFormatRecognizesCrlfPayloads() {
        #expect(LocalToolsSupport.isBeginPatchFormat(crlf(["*** Begin Patch", "*** End Patch"])))
        #expect(LocalToolsSupport.isBeginPatchFormat(crlf(["*** Begin Patch", "*** End Patch", ""])))
        #expect(LocalToolsSupport.isBeginPatchFormat(crlf(["", "", "*** Begin Patch", "*** End Patch"])))
        #expect(LocalToolsSupport.isBeginPatchFormat("*** Begin Patch\r"))
        #expect(LocalToolsSupport.isBeginPatchFormat(lf(["*** Begin Patch", "*** End Patch"])))
    }

    @Test func isBeginPatchFormatStillRejectsOtherFirstLines() {
        #expect(!LocalToolsSupport.isBeginPatchFormat(crlf(["--- a/f.txt", "+++ b/f.txt"])))
        #expect(!LocalToolsSupport.isBeginPatchFormat(crlf(["  *** Begin Patch", "*** End Patch"])))
        #expect(!LocalToolsSupport.isBeginPatchFormat(crlf(["*** Begin Patch now", "*** End Patch"])))
        #expect(!LocalToolsSupport.isBeginPatchFormat(""))
    }

    @Test func crlfBeginPatchUpdateAppliesToACrlfFileAndKeepsItCrlf() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\nthree\r\n", to: file)
        let lines = [
            "*** Begin Patch",
            "*** Update File: f.txt",
            "@@",
            " one",
            "-two",
            "+TWO",
            " three",
            "*** End Patch"
        ]

        try await applyPatch(crlf(lines), root: root)

        #expect(try bytes(of: file) == bytes("one\r\nTWO\r\nthree\r\n"))
        #expect(try entries(in: root) == ["f.txt"])
    }

    @Test func crlfBeginPatchEndingWithACrlfStillFindsItsEndMarker() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\nthree\r\n", to: file)

        // `*** End Patch` is followed by `\r\n` here, so the marker line is
        // `*** End Patch\r` and a final empty line follows it.
        try await applyPatch(crlf([
            "*** Begin Patch",
            "*** Update File: f.txt",
            "@@",
            " one",
            "-two",
            "+TWO",
            " three",
            "*** End Patch",
            ""
        ]), root: root)

        #expect(try bytes(of: file) == bytes("one\r\nTWO\r\nthree\r\n"))
    }

    @Test func crlfBeginPatchAddsAndDeletesFilesInOnePatch() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let gone = root.appendingPathComponent("gone.txt")
        try write("bye\r\n", to: gone)
        try write("keep\r\n", to: root.appendingPathComponent("keep.txt"))

        try await applyPatch(crlf([
            "*** Begin Patch",
            "*** Add File: dir/new.txt",
            "+alpha",
            "+",
            "+beta",
            Self.noNewlineMarker,
            "*** Delete File: gone.txt",
            "*** End Patch",
            ""
        ]), root: root)

        #expect(try bytes(of: root.appendingPathComponent("dir/new.txt")) == bytes("alpha\r\n\r\nbeta\r\n"))
        #expect(try entries(in: root) == ["dir", "keep.txt"])
        #expect(try entries(in: root.appendingPathComponent("dir")) == ["new.txt"])
        #expect(try bytes(of: root.appendingPathComponent("keep.txt")) == bytes("keep\r\n"))
    }

    @Test func crlfBeginPatchWithoutAnEndMarkerIsStillRejected() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let failure = try await failureOfApplying(crlf([
            "*** Begin Patch",
            "*** Add File: new.txt",
            "+alpha"
        ]), root: root)

        #expect(failure?.contains("missing *** End Patch") == true)
        #expect(try entries(in: root).isEmpty)
    }

    // MARK: - Byte-exact line content

    @Test func lfUnifiedDiffDoesNotMatchACrlfFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\n", to: file)

        let failure = try await failureOfApplying(lf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,2 +1,2 @@",
            " one",
            "-two",
            "+TWO"
        ]), root: root)

        #expect(failure?.contains("Patch context mismatch in f.txt at line 1") == true)
        #expect(try bytes(of: file) == bytes("one\r\ntwo\r\n"))
    }

    @Test func crlfUnifiedDiffDoesNotMatchAnLfFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\ntwo\n", to: file)

        let failure = try await failureOfApplying(crlf([
            "--- a/f.txt",
            "+++ b/f.txt",
            "@@ -1,2 +1,2 @@",
            " one",
            "-two",
            "+TWO",
            Self.noNewlineMarker
        ]), root: root)

        #expect(failure?.contains("Patch context mismatch in f.txt at line 1") == true)
        #expect(try bytes(of: file) == bytes("one\ntwo\n"))
    }

    @Test func lfBeginPatchDoesNotMatchACrlfFile() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("f.txt")
        try write("one\r\ntwo\r\n", to: file)

        let failure = try await failureOfApplying(lf([
            "*** Begin Patch",
            "*** Update File: f.txt",
            "@@",
            " one",
            "-two",
            "+TWO",
            "*** End Patch"
        ]), root: root)

        #expect(failure?.contains("Patch hunk did not match f.txt") == true)
        #expect(try bytes(of: file) == bytes("one\r\ntwo\r\n"))
    }

    @Test func lfPatchesStillApplyToLfFiles() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let unified = root.appendingPathComponent("unified.txt")
        let begin = root.appendingPathComponent("begin.txt")
        try write("one\ntwo\n", to: unified)
        try write("one\ntwo\n", to: begin)

        try await applyPatch(lf([
            "--- a/unified.txt",
            "+++ b/unified.txt",
            "@@ -1,2 +1,2 @@",
            " one",
            "-two",
            "+TWO"
        ]), root: root)
        try await applyPatch(lf([
            "*** Begin Patch",
            "*** Update File: begin.txt",
            "@@",
            " one",
            "-two",
            "+TWO",
            "*** End Patch"
        ]), root: root)

        #expect(try bytes(of: unified) == bytes("one\nTWO\n"))
        #expect(try bytes(of: begin) == bytes("one\nTWO\n"))
    }
}
}
