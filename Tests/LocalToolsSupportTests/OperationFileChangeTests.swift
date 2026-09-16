import Foundation
import Testing
import FeatureKit
import ToolCore
@testable import LocalToolsSupport
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite(.serialized)
struct OperationFileChangeTests {
    private func workspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func invoke(_ name: String, _ arguments: [String: Any], root: URL,
                        recorder: OperationFileChangeRecorder? = nil) async throws {
        let tool = try #require(LocalFeatureTools.fileTools().first { $0.descriptor.name == name })
        let data = try JSONSerialization.data(withJSONObject: arguments)
        _ = try await OperationFileChangeRecorder.$current.withValue(recorder) {
            try await tool.invoke(inputData: data, context: FeatureContext(workingDirectory: root, environment: [:]))
        }
    }

    @Test func writeThenAppendRecordsActualOperationBoundaries() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = OperationFileChangeRecorder()
        let second = OperationFileChangeRecorder()
        try await invoke("local.writeFile", ["path": "file", "content": "one"], root: root, recorder: first)
        try await invoke("local.append", ["path": "file", "content": "two"], root: root, recorder: second)
        #expect(first.changes == [.init(path: root.appendingPathComponent("file").path, oldText: nil, newText: "one")])
        #expect(second.changes == [.init(path: root.appendingPathComponent("file").path, oldText: "one", newText: "onetwo")])
    }

    @Test func failedEditHasNoDiffAndBinaryHasExplicitFallback() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([0xff, 0x00]).write(to: file)
        let edit = OperationFileChangeRecorder()
        do {
            try await invoke("local.editFile", ["path": "file", "old": "missing", "new": "replacement"], root: root, recorder: edit)
            Issue.record("Invalid UTF-8 edit unexpectedly succeeded")
        } catch {}
        #expect(edit.changes.isEmpty)
        let write = OperationFileChangeRecorder()
        try await invoke("local.writeFile", ["path": "file", "content": "text"], root: root, recorder: write)
        #expect(write.changes.count == 1)
        #expect(write.changes.first?.explanation != nil)
    }

    @Test func invalidMultiFilePatchPublishesNoPartialEvidence() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "one\n".write(to: root.appendingPathComponent("first"), atomically: true, encoding: .utf8)
        let recorder = OperationFileChangeRecorder()
        let patch = "*** Begin Patch\n*** Update File: first\n@@\n-one\n+two\n*** Update File: missing\n@@\n-no\n+yes\n*** End Patch"
        do {
            try await invoke("local.applyPatch", ["patch": patch], root: root, recorder: recorder)
            Issue.record("Invalid patch unexpectedly succeeded")
        } catch {}
        #expect(recorder.changes.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("first"), encoding: .utf8) == "one\n")
    }

    @Test func opaqueOverlapDegradesToText() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        OperationMutationUncertainty.begin()
        defer { OperationMutationUncertainty.end() }
        let recorder = OperationFileChangeRecorder()
        try await invoke("local.writeFile", ["path": "file", "content": "text"], root: root, recorder: recorder)
        #expect(recorder.changes.first?.explanation != nil)
        #expect(recorder.changes.first?.newText == nil)
    }

    @Test func simultaneousWritersKeepDistinctEvidence() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = OperationFileChangeRecorder()
        let second = OperationFileChangeRecorder()
        async let a: Void = invoke("local.writeFile", ["path": "file", "content": "A"], root: root, recorder: first)
        async let b: Void = invoke("local.writeFile", ["path": "file", "content": "B"], root: root, recorder: second)
        _ = try await (a, b)
        #expect(first.changes.first?.newText == "A")
        #expect(second.changes.first?.newText == "B")
        let old = [first.changes.first?.oldText, second.changes.first?.oldText]
        #expect(old.filter { $0 == nil }.count == 1)
        #expect(old.contains("A") || old.contains("B"))
    }
}

extension OperationFileChangeTests {
    @Test func successfulPatchRecordsCommittedTextsNotPatchSource() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let recorder = OperationFileChangeRecorder()
        try await invoke("local.applyPatch", ["patch": "*** Begin Patch\n*** Update File: file\n@@\n-before\n+after\n*** End Patch"], root: root, recorder: recorder)
        #expect(recorder.changes == [.init(path: file.path, oldText: "before\n", newText: "after\n")])
    }

    @Test func moveAndDeletePreserveMissingFileMeaning() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        try "text".write(to: root.appendingPathComponent("source"), atomically: true, encoding: .utf8)
        let move = OperationFileChangeRecorder()
        try await invoke("local.move", ["sourcePath": "source", "destinationPath": "destination"], root: root, recorder: move)
        #expect(move.changes == [
            .init(path: root.appendingPathComponent("source").path, oldText: "text", newText: nil),
            .init(path: root.appendingPathComponent("destination").path, oldText: nil, newText: "text")
        ])
        let deletion = OperationFileChangeRecorder()
        try await invoke("local.delete", ["path": "destination"], root: root, recorder: deletion)
        #expect(deletion.changes == [.init(path: root.appendingPathComponent("destination").path, oldText: "text", newText: nil)])
        let missing = OperationFileChangeRecorder()
        try await invoke("local.delete", ["path": "destination"], root: root, recorder: missing)
        #expect(missing.changes.isEmpty)
    }
}

extension OperationFileChangeTests {
    @Test func fifoDeleteAndMoveDoNotWaitForWriter() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["local.delete", "local.move"] {
            let source = root.appendingPathComponent(UUID().uuidString)
            #expect(mkfifo(source.path, mode_t(0o600)) == 0)
            let recorder = OperationFileChangeRecorder()
            let done = DispatchSemaphore(value: 0)
            let job = Task.detached {
                defer { done.signal() }
                if name == "local.delete" {
                    try await invoke(name, ["path": source.path], root: root, recorder: recorder)
                } else {
                    try await invoke(name, ["sourcePath": source.path, "destinationPath": "moved"], root: root, recorder: recorder)
                }
            }
            let completed = try await waitForCompletion(done)
            if !completed {
                // Rescue a regressed blocking reader without hanging the suite.
                let fd = open(source.path, O_RDWR | O_NONBLOCK)
                if fd >= 0 { _ = close(fd) }
            }
            try #require(completed, "FIFO mutation waited for a writer")
            try await job.value
            #expect(!recorder.changes.isEmpty)
            #expect(recorder.changes.allSatisfy { $0.explanation != nil && $0.oldText == nil && $0.newText == nil })
            #expect(!FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test func oversizedBeforeAndAfterFallBackWithoutChangingWrites() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let large = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes + 1)
        try large.write(to: file, atomically: true, encoding: .utf8)
        let old = OperationFileChangeRecorder()
        try await invoke("local.writeFile", ["path": "file", "content": "small"], root: root, recorder: old)
        #expect(old.changes.first?.explanation != nil)
        #expect(old.changes.first?.oldText == nil)
        let new = OperationFileChangeRecorder()
        try await invoke("local.writeFile", ["path": "file", "content": large], root: root, recorder: new)
        #expect(new.changes.first?.explanation != nil)
        #expect(new.changes.first?.newText == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == large)
        let deletion = OperationFileChangeRecorder()
        try await invoke("local.delete", ["path": "file"], root: root, recorder: deletion)
        #expect(deletion.changes.first?.explanation != nil)
    }

    @Test func aggregatePatchEvidenceIsBoundedButEveryFileIsWritten() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "x", count: 48 * 1024)
        let sections = (0..<8).map { "*** Add File: file\($0)\n+\(text)" }
        let recorder = OperationFileChangeRecorder()
        try await invoke("local.applyPatch", ["patch": "*** Begin Patch\n" + sections.joined(separator: "\n") + "\n*** End Patch"], root: root, recorder: recorder)
        #expect(recorder.changes.count == 8)
        let bytes = recorder.changes.reduce(0) { $0 + ($1.oldText?.utf8.count ?? 0) + ($1.newText?.utf8.count ?? 0) }
        #expect(bytes <= OperationFileChangeRecorder.maximumOperationBytes)
        #expect(recorder.changes.contains { $0.explanation != nil })
        for index in 0..<8 {
            #expect(try String(contentsOf: root.appendingPathComponent("file\(index)"), encoding: .utf8) == text + "\n")
        }
    }

    @Test func editsRecordSuccessfulBoundaries() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try "one two one".write(to: file, atomically: true, encoding: .utf8)
        let edit = OperationFileChangeRecorder()
        try await invoke("local.editFile", ["path": "file", "old": "two", "new": "three"], root: root, recorder: edit)
        #expect(edit.changes == [.init(path: file.path, oldText: "one two one", newText: "one three one")])
        let replace = OperationFileChangeRecorder()
        try await invoke("local.replace", ["path": "file", "old": "one", "new": "four"], root: root, recorder: replace)
        #expect(replace.changes == [.init(path: file.path, oldText: "one three one", newText: "four three four")])
        let multi = OperationFileChangeRecorder()
        try await invoke("local.multiEdit", ["path": "file", "edits": [["old": "three", "new": "five"], ["old": "four five", "new": "six"]]], root: root, recorder: multi)
        #expect(multi.changes == [.init(path: file.path, oldText: "four three four", newText: "six four")])
    }

    @Test func binaryAppendPreservesBytesAndEmitsOnlyFallback() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([0xff, 0]).write(to: file)
        let recorder = OperationFileChangeRecorder()
        try await invoke("local.append", ["path": "file", "content": "text"], root: root, recorder: recorder)
        #expect(try Data(contentsOf: file) == Data([0xff, 0]) + Data("text".utf8))
        #expect(recorder.changes.first?.explanation != nil)
        #expect(recorder.changes.first?.oldText == nil)
        #expect(recorder.changes.first?.newText == nil)
    }

    @Test func postCommitPatchFaultRollsBackWithoutEvidence() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        let recorder = OperationFileChangeRecorder()
        do {
            try await LocalApplyPatchTool.$failAfterCommitCount.withValue(1) {
                try await invoke("local.applyPatch", ["patch": "*** Begin Patch\n*** Update File: file\n@@\n-before\n+after\n*** Add File: other\n+new\n*** End Patch"], root: root, recorder: recorder)
            }
            Issue.record("Injected post-commit failure unexpectedly succeeded")
        } catch {}
        #expect(recorder.changes.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "before\n")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other").path))
    }
}

extension OperationFileChangeTests {
    @Test func multifileSnapshotBudgetFallsBackAfterLimit() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes)
        for index in 0..<6 {
            try text.write(to: root.appendingPathComponent("file\(index)"), atomically: true, encoding: .utf8)
        }
        let recorder = OperationFileChangeRecorder()
        let sections = (0..<6).map { "*** Delete File: file\($0)" }.joined(separator: "\n")
        try await invoke("local.applyPatch", ["patch": "*** Begin Patch\n" + sections + "\n*** End Patch"], root: root, recorder: recorder)
        #expect(recorder.changes.count == 6)
        #expect(recorder.changes.filter { $0.oldText != nil }.count == 4)
        #expect(recorder.changes.suffix(2).allSatisfy { $0.explanation != nil && $0.oldText == nil })
        for index in 0..<6 {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("file\(index)").path))
        }
    }

    @Test func symlinkToFIFOIsNotOpenedForEvidence() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo")
        let link = root.appendingPathComponent("link")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        let recorder = OperationFileChangeRecorder()
        let evidence = OperationFileChangeRecorder.$current.withValue(recorder) {
            LocalOperationWrite.snapshot(link)
        }
        #expect(evidence == nil)
    }
}

extension OperationFileChangeTests {
    @Test func concurrentWritesShareAggregateRecorderBudget() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = OperationFileChangeRecorder()
        let text = String(repeating: "x", count: 32 * 1024)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask {
                    try await invoke("local.writeFile", ["path": "file\(index)", "content": text], root: root, recorder: recorder)
                }
            }
            try await group.waitForAll()
        }
        #expect(recorder.changes.count == 16)
        #expect(recorder.changes.filter { $0.newText == text }.count == 8)
        #expect(recorder.changes.filter { $0.explanation != nil }.count == 8)
        for index in 0..<16 {
            #expect(try String(contentsOf: root.appendingPathComponent("file\(index)"), encoding: .utf8) == text)
        }
    }

    @Test func oversizedAppendHasNoInventedDeletion() async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        let original = String(repeating: "x", count: OperationFileChangeRecorder.maximumTextBytes)
        try original.write(to: file, atomically: true, encoding: .utf8)
        let recorder = OperationFileChangeRecorder()
        try await invoke("local.append", ["path": "file", "content": "y"], root: root, recorder: recorder)
        #expect(recorder.changes.first?.explanation != nil)
        #expect(recorder.changes.first?.oldText == nil)
        #expect(recorder.changes.first?.newText == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == original + "y")
    }
}

private extension OperationFileChangeTests {
    func waitForCompletion(_ semaphore: DispatchSemaphore) async throws -> Bool {
        try await LocalIOOffloader.run {
            semaphore.wait(timeout: .now() + 3) == .success
        }
    }

    /// Wait for the special-I/O branch, not an arbitrary sleep before the probe.
    func waitForSpecialIO() async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if OperationMutationUncertainty.snapshot == nil { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
}

extension OperationFileChangeTests {
    @Test(arguments: [false, true], [false, true])
    func fifoAppendAndPatchDoNotHoldMutationLock(patch: Bool, recording: Bool) async throws {
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let fifo = root.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, mode_t(0o600)) == 0)
        // Follow a symlink as the original mutations do, while checking the
        // opened object rather than trusting a preflight path classification.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fifo)
        let recorder = recording ? OperationFileChangeRecorder() : nil
        let done = DispatchSemaphore(value: 0)
        let special = Task.detached {
            defer { done.signal() }
            if patch {
                try await invoke("local.applyPatch", ["patch": "*** Begin Patch\n*** Update File: link\n@@\n-before\n+after\n*** End Patch"], root: root, recorder: recorder)
            } else {
                try await invoke("local.append", ["path": "link", "content": "payload"], root: root, recorder: recorder)
            }
        }
        // Foundation may reject a FIFO read immediately instead of waiting for
        // a writer. Observe completion without connecting a peer first.
        let completedBeforeProbe = try await waitForCompletion(done)
        let enteredSpecialIO = !completedBeforeProbe && OperationMutationUncertainty.snapshot == nil
        let normalRecorder = OperationFileChangeRecorder()
        let normalDone = DispatchSemaphore(value: 0)
        let normal = Task.detached {
            defer { normalDone.signal() }
            try await invoke("local.writeFile", ["path": "ordinary", "content": "independent"], root: root, recorder: normalRecorder)
        }
        // Measure before connecting either end of the FIFO. The second write
        // must finish while the first operation is still waiting for its peer.
        let normalCompleted = try await waitForCompletion(normalDone)

        // Always rescue before assertions, including when the old locking bug
        // regresses. Nonblocking peer opens and bounded retries prevent cleanup
        // itself from becoming an infinite wait.
        let peer = try await LocalIOOffloader.run {
            if completedBeforeProbe { return Int32(-1) }
            if !patch { return open(fifo.path, O_RDONLY | O_NONBLOCK) }
            let deadline = Date().addingTimeInterval(3)
            repeat {
                let fd = open(fifo.path, O_WRONLY | O_NONBLOCK)
                if fd >= 0 {
                    // Keep a reader of our own during the write so a failed
                    // Foundation read cannot turn cleanup into SIGPIPE.
                    let safetyReader = open(fifo.path, O_RDONLY | O_NONBLOCK)
                    if safetyReader >= 0 {
                        let bytes = Array("before\n".utf8)
                        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                        _ = close(safetyReader)
                    }
                    _ = close(fd)
                    return Int32(-1)
                }
                Thread.sleep(forTimeInterval: 0.005)
            } while Date() < deadline
            return Int32(-1)
        }
        // Keep the append reader alive until the writer has completed.
        defer { if peer >= 0 { _ = close(peer) } }
        let specialCompleted: Bool
        if completedBeforeProbe {
            specialCompleted = true
        } else {
            specialCompleted = try await waitForCompletion(done)
        }
        let normalRescued: Bool
        if normalCompleted {
            normalRescued = true
        } else {
            normalRescued = try await waitForCompletion(normalDone)
        }
        if !specialCompleted { special.cancel() }
        if !normalRescued { normal.cancel() }
        #expect(normalCompleted, "FIFO I/O blocked an unrelated regular-file write")
        try #require(specialCompleted, "FIFO emergency peer did not release the operation")
        try #require(normalRescued, "Regular write did not complete after FIFO rescue")
        var rejectedFIFORead = false
        do {
            try await special.value
        } catch {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            guard patch, completedBeforeProbe,
                  failure.domain == NSCocoaErrorDomain, failure.code == 257,
                  underlying?.domain == NSPOSIXErrorDomain, underlying?.code == Int(EACCES) else {
                throw error
            }
            rejectedFIFORead = true
        }
        try await normal.value
        #expect(try String(contentsOf: root.appendingPathComponent("ordinary"), encoding: .utf8) == "independent")
        if rejectedFIFORead {
            #expect(recorder?.changes.isEmpty ?? true)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == fifo.path)
            var fifoInfo = stat()
            try #require(lstat(fifo.path, &fifoInfo) == 0)
            #expect((fifoInfo.st_mode & S_IFMT) == S_IFIFO)
            #expect(normalRecorder.changes == [.init(path: root.appendingPathComponent("ordinary").path, oldText: nil, newText: "independent")])
        } else {
            #expect(!completedBeforeProbe, "FIFO operation completed without its peer")
            #expect(enteredSpecialIO, "FIFO never entered the unlocked special-I/O branch")
            #expect(normalRecorder.changes.allSatisfy { $0.explanation != nil })
            if let recorder {
                #expect(!recorder.changes.isEmpty)
                #expect(recorder.changes.allSatisfy { $0.explanation != nil && $0.oldText == nil && $0.newText == nil })
            }
        }
    }
}
