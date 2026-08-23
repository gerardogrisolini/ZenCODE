//
//  LocalIOOffloaderTests.swift
//  LocalToolsSupportTests
//
//  Verifies that the core local file/text tools keep their exact contracts
//  (output/range/messages) while performing blocking I/O off the cooperative
//  thread pool, and that cooperative cancellation is honored at the offload
//  boundary.
//

import Foundation
import Testing
import FeatureKit
import LocalToolsSupport

@Suite
struct LocalIOOffloaderTests {
    // MARK: - Cancellation

    @Test
    /// A tool call cancelled *before* its offloaded I/O begins must fail fast
    /// with CancellationError rather than performing the read. This is the
    /// deterministic boundary at which `LocalIOOffloader.run` observes
    /// cancellation. A blocking syscall in flight cannot be interrupted, so we
    /// only assert the boundary case.
    func offloadedReadHonorsCancellationBeforeIO() async throws {
        let root = try Self.makeTempDir("cancel-read")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.txt")
        // A sizable payload so a real read would be observable if it slipped
        // through; cancellation must still win because the task is already
        // cancelled when the offloader runs.
        try String(repeating: "payload-line\n", count: 50_000)
            .write(to: file, atomically: true, encoding: .utf8)

        let gate = TestGate()
        let readFile = try #require(
            LocalFeatureTools.fileTools().first { $0.descriptor.name == "local.readFile" }
        )

        let task = Task<String, Error> {
            await gate.wait() // park until the test has cancelled and opened the gate
            let output = try await readFile.invoke(
                inputData: try JSONSerialization.data(withJSONObject: ["path": file.path]),
                context: FeatureContext(workingDirectory: root, environment: [:])
            )
            return String(decoding: output, as: UTF8.self)
        }
        task.cancel() // cancel while the task is parked at the gate
        await gate.open() // resume into an already-cancelled task

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Contract preservation (functional correctness via the offload path)

    @Test
    func offloadedReadFileAppliesOffsetAndLimitExactly() async throws {
        let root = try Self.makeTempDir("readfile-range")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("five.txt")
        try "a\nb\nc\nd\ne".write(to: file, atomically: true, encoding: .utf8)

        let output = try await Self.invoke(
            "local.readFile",
            arguments: ["path": file.path, "offset": 2, "limit": 2],
            workingDirectory: root
        )
        // lines 2 and 3, each prefixed with its 1-based index and a tab.
        #expect(output == "2\tb\n3\tc")
    }

    @Test
    func offloadedWriteFileReportsBytesAndPersistsContent() async throws {
        let root = try Self.makeTempDir("writefile")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("out.txt")
        let content = "héllo\nworld\n"

        let message = try await Self.invoke(
            "local.writeFile",
            arguments: ["path": file.path, "content": content],
            workingDirectory: root
        )
        #expect(message == "Wrote \(file.path) (\(content.utf8.count) bytes).")

        // Round-trip via the offloaded read path.
        let readBack = try await Self.invoke(
            "local.readFile",
            arguments: ["path": file.path, "limit": 10],
            workingDirectory: root
        )
        #expect(readBack == "1\théllo\n2\tworld\n3\t")
    }

    @Test
    func offloadedEditFileUpdatesOnceAndReportsReplacementCount() async throws {
        let root = try Self.makeTempDir("editfile")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("src.txt")
        try "foo bar baz".write(to: file, atomically: true, encoding: .utf8)

        let message = try await Self.invoke(
            "local.editFile",
            arguments: ["path": file.path, "old": "bar", "new": "qux"],
            workingDirectory: root
        )
        #expect(message.hasPrefix("Updated \(file.path). Replacements: 1."))
        #expect(try String(contentsOf: file, encoding: .utf8) == "foo qux baz")
    }

    @Test
    /// multiEdit is read off-pool, validated/transformed on-pool (so a long
    /// edit list is cancellable between edits), then written off-pool. A
    /// failing edit must leave the file untouched, preserving atomicity.
    func offloadedMultiEditRollsBackOnFailureAndStaysUntouched() async throws {
        let root = try Self.makeTempDir("multiedit")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("doc.txt")
        let original = "alpha\nbeta\ngamma\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        await #expect(throws: (any Error).self) {
            _ = try await Self.invoke(
                "local.multiEdit",
                arguments: [
                    "path": file.path,
                    "edits": [
                        ["old": "beta", "new": "BETA"],
                        ["old": "absent", "new": "x"]
                    ]
                ],
                workingDirectory: root
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test
    func offloadedReadFilesContinuesAcrossPerFileErrors() async throws {
        let root = try Self.makeTempDir("readfiles-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("present.txt")
        try "ok".write(to: present, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("missing.txt")

        let output = try await Self.invoke(
            "local.readFiles",
            arguments: ["paths": [present.path, missing.path], "limit": 10],
            workingDirectory: root
        )
        #expect(output.contains("===== \(present.path) ====="))
        #expect(output.contains("1\tok"))
        #expect(output.contains("===== \(missing.path) ====="))
        #expect(output.contains("<error:"))
    }

    // MARK: - Text tools

    @Test
    func offloadedTextHeadTailAndWordCountAreExact() async throws {
        let root = try Self.makeTempDir("texttools")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lines.txt")
        try "one\ntwo\nthree\nfour\nfive".write(to: file, atomically: true, encoding: .utf8)

        let head = try await Self.invoke(
            "text.head",
            arguments: ["path": file.path, "lines": 2],
            workingDirectory: root
        )
        #expect(head == "File: \(file.path)\n1\tone\n2\ttwo")

        let tail = try await Self.invoke(
            "text.tail",
            arguments: ["path": file.path, "lines": 2],
            workingDirectory: root
        )
        #expect(tail == "File: \(file.path)\n4\tfour\n5\tfive")

        let wc = try await Self.invoke(
            "text.wc",
            arguments: ["path": file.path],
            workingDirectory: root
        )
        // 5 newline-separated components for 5 lines (no trailing newline).
        #expect(wc == """
        File: \(file.path)
        lines: 5
        words: 5
        characters: 23
        """)
    }

    // MARK: - Concurrency (offload does not deadlock or corrupt results)

    @Test
    /// Many concurrent offloaded reads must each return their own file's
    /// content, demonstrating the dedicated I/O queue absorbs parallel blocking
    /// reads without starvation or data races.
    func concurrentOffloadedReadsAllReturnCorrectContent() async throws {
        let root = try Self.makeTempDir("concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = try #require(
            LocalFeatureTools.fileTools().first { $0.descriptor.name == "local.readFile" }
        )
        let context = FeatureContext(workingDirectory: root, environment: [:])

        let count = 32
        var files: [URL] = []
        for index in 0..<count {
            let url = root.appendingPathComponent("row-\(index).txt")
            try "row \(index)".write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }

        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (index, file) in files.enumerated() {
                group.addTask {
                    let output = try await tool.invoke(
                        inputData: try JSONSerialization.data(withJSONObject: ["path": file.path]),
                        context: context
                    )
                    let body = (try? JSONDecoder().decode(String.self, from: output))
                        ?? String(decoding: output, as: UTF8.self)
                    return (index, body)
                }
            }
            var collected = [Int: String]()
            for try await (index, output) in group {
                collected[index] = output
            }
            return collected
        }

        for index in 0..<count {
            #expect(results[index] == "1\trow \(index)")
        }
    }

    // MARK: - Helpers

    private static func makeTempDir(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("localio-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func invoke(
        _ name: String,
        arguments: [String: Any],
        workingDirectory: URL
    ) async throws -> String {
        let tool = LocalFeatureTools.fileTools().first { $0.descriptor.name == name }
            ?? LocalFeatureTools.textTools().first { $0.descriptor.name == name }
        let unwrapped = try #require(tool)
        let data = try JSONSerialization.data(withJSONObject: arguments)
        let output = try await unwrapped.invoke(
            inputData: data,
            context: FeatureContext(workingDirectory: workingDirectory, environment: [:])
        )
        // The tool result is JSON-encoded (a String value becomes `"…"` with
        // escaped tabs/slashes); decode it back to a real String.
        if let decoded = try? JSONDecoder().decode(String.self, from: output) {
            return decoded
        }
        return String(decoding: output, as: UTF8.self)
    }
}

/// A single-shot async gate used to deterministically control when a task may
/// proceed, so cancellation can be arranged before the task performs I/O.
///
/// Order-independent: if `open()` runs before `wait()`, the later `wait()`
/// returns immediately, so the parked task can never miss the open and hang.
private actor TestGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.continuation = continuation
        }
    }

    func open() {
        guard !opened else { return }
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
