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
