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

    // MARK: - Begin Patch

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
}
}
