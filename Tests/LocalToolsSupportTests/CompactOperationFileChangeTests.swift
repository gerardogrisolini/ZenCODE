import Foundation
import Testing
import FeatureKit
import ToolCore
@testable import LocalToolsSupport

extension LocalToolsSerialGroup {
@Suite(.serialized)
struct CompactOperationFileChangeTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func invoke(_ name: String, _ arguments: [String: Any], root: URL,
                        recorder: OperationFileChangeRecorder) async throws {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == name })
        let data = try JSONSerialization.data(withJSONObject: arguments)
        _ = try await OperationFileChangeRecorder.$current.withValue(recorder) {
            try await tool.invoke(inputData: data, context: FeatureContext(workingDirectory: root, environment: [:]))
        }
    }

    private var largeText: String {
        (0..<2200).map { "entry \($0): " + String(repeating: "unchanged text ", count: 5) + "\n" }.joined()
    }

    @Test(arguments: ["local.editFile", "local.replace", "local.multiEdit", "local.writeFile", "local.applyPatch", "local.append"])
    func smallEditsToLargeFilesRetainOnlyExactCompactEvidence(tool: String) async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("CHANGELOG.md")
        let old = largeText
        #expect(old.utf8.count > OperationFileChangeRecorder.maximumTextBytes)
        try old.write(to: path, atomically: true, encoding: .utf8)
        let originalLine = "entry 1200: " + String(repeating: "unchanged text ", count: 5)
        let changedLine = "entry 1200: changed café 界"
        let new = tool == "local.append" ? old + changedLine + "\n"
            : old.replacingOccurrences(of: originalLine, with: changedLine)
        let arguments: [String: Any]
        switch tool {
        case "local.applyPatch":
            arguments = ["patch": "*** Begin Patch\n*** Update File: CHANGELOG.md\n@@\n-\(originalLine)\n+\(changedLine)\n*** End Patch"]
        case "local.writeFile": arguments = ["path": "CHANGELOG.md", "content": new]
        case "local.append": arguments = ["path": "CHANGELOG.md", "content": changedLine + "\n"]
        case "local.multiEdit": arguments = ["path": "CHANGELOG.md", "edits": [["old": originalLine, "new": changedLine]]]
        default: arguments = ["path": "CHANGELOG.md", "old": originalLine, "new": changedLine]
        }
        let recorder = OperationFileChangeRecorder()
        try await invoke(tool, arguments, root: root, recorder: recorder)
        #expect(try String(contentsOf: path, encoding: .utf8) == new)
        let change = try #require(recorder.changes.first)
        let compact = try #require(change.compactDiff)
        #expect(change.path == path.path)
        #expect(change.explanation == nil)
        #expect(change.oldText == nil && change.newText == nil)
        #expect(compact.additions == 1)
        #expect(compact.deletions == (tool == "local.append" ? 0 : 1))
        #expect(compact.patch.contains("+" + changedLine + "\n"))
        #expect(!compact.patch.contains("entry 0:"))
        #expect(compact.patch.utf8.count < 2048)
        // A later write cannot alter captured evidence.
        try "unrelated later state".write(to: path, atomically: true, encoding: .utf8)
        #expect(recorder.changes.first == change)
    }

    @Test func scratchAndAnalysisReservationsAreSeparateFromRetainedEvidence() {
        let recorder = OperationFileChangeRecorder()
        let size = OperationFileChangeRecorder.maximumSnapshotBytes
        #expect(!recorder.reserveSnapshotBytes(-1))
        #expect(!recorder.reserveSnapshotBytes(size + 1))
        for _ in 0..<4 { #expect(recorder.reserveSnapshotBytes(size)) }
        #expect(!recorder.reserveSnapshotBytes(1))
        #expect(!recorder.reserveDiffInputBytes(-1))
        #expect(!recorder.reserveDiffInputBytes(2 * size + 1))
        #expect(recorder.reserveDiffInputBytes(2 * size))
        #expect(recorder.reserveDiffInputBytes(2 * size))
        #expect(!recorder.reserveDiffInputBytes(1))
        recorder.record(.init(path: "small", oldText: "before", newText: "after"))
        #expect(recorder.changes.first?.explanation == nil)
        #expect(recorder.remainingDiffBytes == OperationFileChangeRecorder.maximumTextBytes)
    }

    @Test func compactPatchesShareTheOriginalPerFileAndOperationOutputBudget() {
        let recorder = OperationFileChangeRecorder()
        let patch = String(repeating: "+", count: OperationFileChangeRecorder.maximumTextBytes)
        for index in 0..<5 {
            recorder.record(.init(path: "file\(index)", oldText: nil, newText: nil,
                compactDiff: .init(patch: patch, additions: 1, deletions: 0)))
        }
        #expect(recorder.changes.prefix(4).allSatisfy { $0.compactDiff?.patch == patch })
        #expect(recorder.changes.last?.compactDiff == nil)
        #expect(recorder.changes.last?.explanation?.contains("byte limit") == true)
        #expect(recorder.remainingDiffBytes == 0)
        let oversized = OperationFileChangeRecorder()
        oversized.record(.init(path: "large", oldText: nil, newText: nil,
            compactDiff: .init(patch: patch + "+", additions: 1, deletions: 0)))
        #expect(oversized.changes.first?.compactDiff == nil)
        #expect(oversized.changes.first?.explanation != nil)
        let mixed = OperationFileChangeRecorder()
        mixed.record(.init(path: "snapshots", oldText: patch, newText: patch))
        for index in 0..<3 {
            mixed.record(.init(path: "compact\(index)", oldText: nil, newText: nil,
                compactDiff: .init(patch: patch, additions: 1, deletions: 0)))
        }
        #expect(mixed.changes[1].compactDiff != nil && mixed.changes[2].compactDiff != nil)
        #expect(mixed.changes[3].compactDiff == nil && mixed.changes[3].explanation != nil)
    }

    @Test func overScratchLimitAndExhaustedAnalysisDoNotChangeMutationSemantics() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        let huge = String(repeating: "x", count: OperationFileChangeRecorder.maximumSnapshotBytes + 1)
        try huge.write(to: file, atomically: true, encoding: .utf8)
        let recorder = OperationFileChangeRecorder()
        let before = OperationFileChangeRecorder.$current.withValue(recorder) { LocalOperationWrite.snapshot(file) }
        #expect(before == nil)
        try await invoke("local.writeFile", ["path": "large", "content": huge + "y"], root: root, recorder: recorder)
        #expect(recorder.changes.first?.compactDiff == nil)
        #expect(recorder.changes.first?.explanation?.contains("byte limit") == true)
        #expect(try String(contentsOf: file, encoding: .utf8) == huge + "y")

        try largeText.write(to: file, atomically: true, encoding: .utf8)
        let exhausted = OperationFileChangeRecorder()
        for _ in 0..<2 { #expect(exhausted.reserveDiffInputBytes(2 * OperationFileChangeRecorder.maximumSnapshotBytes)) }
        try await invoke("local.append", ["path": "large", "content": "new\n"], root: root, recorder: exhausted)
        #expect(exhausted.changes.first?.explanation?.contains("inputs exceed") == true)
        #expect(exhausted.changes.first?.compactDiff == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == largeText + "new\n")
    }

    @Test func largeRewritesAndDenseInputsHaveExplicitComputationFallback() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        for old in [largeText, String(repeating: "\n", count: 70 * 1024)] {
            try old.write(to: file, atomically: true, encoding: .utf8)
            let new = old.replacingOccurrences(of: "entry", with: "changed") + "new\n"
            let recorder = OperationFileChangeRecorder()
            try await invoke("local.writeFile", ["path": "large", "content": new], root: root, recorder: recorder)
            #expect(recorder.changes.first?.compactDiff == nil)
            #expect(recorder.changes.first?.explanation?.contains("computation limit") == true)
            #expect(try String(contentsOf: file, encoding: .utf8) == new)
        }
    }

    @Test func largeBinarySymlinkAndOverlappedInputsNeverGainCompactCertainty() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large")
        for suffix in [Data([0]), Data([0xff])] {
            try (Data(largeText.utf8) + suffix).write(to: file)
            let recorder = OperationFileChangeRecorder()
            try await invoke("local.writeFile", ["path": "large", "content": largeText + "new\n"], root: root, recorder: recorder)
            #expect(recorder.changes.first?.compactDiff == nil)
            #expect(recorder.changes.first?.explanation?.contains("binary") == true)
        }
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let symlinkRecorder = OperationFileChangeRecorder()
        #expect(OperationFileChangeRecorder.$current.withValue(symlinkRecorder) { LocalOperationWrite.snapshot(link) } == nil)

        let overlapped = OperationFileChangeRecorder()
        try OperationFileChangeRecorder.$current.withValue(overlapped) {
            try LocalOperationWrite.serialized {
                let before = LocalOperationWrite.snapshot(file)
                OperationMutationUncertainty.begin()
                OperationMutationUncertainty.end()
                let after = largeText + "newer\n"
                try after.write(to: file, atomically: true, encoding: .utf8)
                LocalOperationWrite.record(path: file, existed: true, before: before, after: after)
            }
        }
        #expect(overlapped.changes.first?.compactDiff == nil)
        #expect(overlapped.changes.first?.explanation?.contains("overlapped") == true)
    }
}
}
