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

extension LocalToolsSerialGroup {
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
}

extension LocalToolsSerialGroup.OperationFileChangeTests {
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

extension LocalToolsSerialGroup.OperationFileChangeTests {
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
}

private extension LocalToolsSerialGroup.OperationFileChangeTests {
    func waitForCompletion(_ semaphore: DispatchSemaphore) async throws -> Bool {
        try await LocalIOOffloader.run {
            semaphore.wait(timeout: .now() + 3) == .success
        }
    }

    func isCocoaPermissionDeniedByPOSIXAccess(_ error: any Error) -> Bool {
        let failure = error as NSError
        // Corelibs stores NSUnderlyingErrorKey as a native POSIXError. Extract
        // Error first so the subsequent Error-to-NSError bridge is performed.
        guard failure.domain == NSCocoaErrorDomain, failure.code == 257,
              let underlyingError = failure.userInfo[NSUnderlyingErrorKey] as? any Error else {
            return false
        }
        let underlyingFailure = underlyingError as NSError
        return underlyingFailure.domain == NSPOSIXErrorDomain && underlyingFailure.code == Int(EACCES)
    }
}

extension LocalToolsSerialGroup.OperationFileChangeTests {
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
            // Corelibs Foundation on Linux may reject this FIFO symlink read
            // with Cocoa 257 / POSIX EACCES either before a peer is connected
            // or only after its blocking open/read is released. That delivery
            // timing is orthogonal to the lock invariant: normalCompleted was
            // measured before connecting either end of the FIFO.
            guard patch, isCocoaPermissionDeniedByPOSIXAccess(error) else {
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
            // If the EACCES raced the timeout, the ordinary write may have
            // overlapped special I/O and conservatively recorded a fallback;
            // it still must produce exactly one valid evidence entry.
            let expectedNormal = OperationFileChange(
                path: root.appendingPathComponent("ordinary").path,
                oldText: nil,
                newText: "independent"
            )
            #expect(normalRecorder.changes.count == 1)
            let normalChange = try #require(normalRecorder.changes.first)
            #expect(normalChange.path == expectedNormal.path)
            #expect(normalChange == expectedNormal ||
                (normalChange.oldText == nil && normalChange.newText == nil && normalChange.explanation != nil))
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
