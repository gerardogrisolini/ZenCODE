@testable import FeatureMCPBridgeKit
import Foundation
import Synchronization
import Testing

#if os(macOS)
import Darwin

@Suite
struct MCPStreamPumpCharacterizationTests {
    @Test
    func stdoutPumpForwardsBytesThenReportsEOF() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let chunks = Mutex<[Data]>([])
        pipe.fileHandleForWriting.write(Data("stdout".utf8))
        pipe.fileHandleForWriting.closeFile()

        let termination = await MCPStreamPump.run(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            onChunk: { chunk in chunks.withLock { $0.append(chunk) } },
            shouldStop: { false }
        )

        #expect(termination == .endOfFile)
        #expect(chunks.withLock { $0 } == [Data("stdout".utf8)])
    }

    @Test
    func stderrPumpUsesTheSameChunkContract() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let chunks = Mutex<[Data]>([])
        pipe.fileHandleForWriting.write(Data("stderr".utf8))
        pipe.fileHandleForWriting.closeFile()

        let termination = await MCPStreamPump.run(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            onChunk: { chunk in chunks.withLock { $0.append(chunk) } },
            shouldStop: { false }
        )

        #expect(termination == .endOfFile)
        #expect(chunks.withLock { $0 } == [Data("stderr".utf8)])
    }

    @Test
    func invalidDescriptorReportsReadFailureInsteadOfEOF() async {
        let termination = await MCPStreamPump.run(
            fileDescriptor: -1,
            onChunk: { _ in },
            shouldStop: { false }
        )

        guard case let .failure(code) = termination else {
            Issue.record("Expected a read failure, got \(termination)")
            return
        }
        #expect(code == .EBADF)
    }

    @Test
    func cancellationIsNotReportedAsEOFOrFailure() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let task = Task {
            await MCPStreamPump.run(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                onChunk: { _ in },
                shouldStop: { false }
            )
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func policyStopIsDistinctFromCancellationAndEOF() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)

        let termination = await MCPStreamPump.run(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            onChunk: { _ in },
            shouldStop: { true }
        )

        #expect(termination == .stopped)
        pipe.fileHandleForWriting.closeFile()
    }

    /// Counts typed-handler invocations so routing tests can assert which
    /// handler fired without depending on timing.
    private final class HandlerRecorder: Sendable {
        private final class Counts: @unchecked Sendable {
            let lock = NSLock()
            var chunks = 0
            var endOfFile = 0
            var readFailures = 0
        }

        private let counts = Counts()

        func recordChunk() {
            counts.lock.lock(); defer { counts.lock.unlock() }
            counts.chunks += 1
        }

        func recordEndOfFile() {
            counts.lock.lock(); defer { counts.lock.unlock() }
            counts.endOfFile += 1
        }

        func recordReadFailure() {
            counts.lock.lock(); defer { counts.lock.unlock() }
            counts.readFailures += 1
        }

        var chunkCount: Int {
            counts.lock.lock(); defer { counts.lock.unlock() }
            return counts.chunks
        }

        var endOfFileCount: Int {
            counts.lock.lock(); defer { counts.lock.unlock() }
            return counts.endOfFile
        }

        var readFailureCount: Int {
            counts.lock.lock(); defer { counts.lock.unlock() }
            return counts.readFailures
        }
    }

    @Test
    func drainRoutesEndOfFileToOnlyTheEndOfFileHandlerOnce() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let recorder = HandlerRecorder()
        pipe.fileHandleForWriting.write(Data("payload".utf8))
        pipe.fileHandleForWriting.closeFile()

        let termination = await MCPStreamPump.drain(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            handlers: MCPStreamPumpHandlers(
                onChunk: { _ in recorder.recordChunk() },
                onEndOfFile: { recorder.recordEndOfFile() },
                onReadFailure: { _ in recorder.recordReadFailure() }
            )
        )

        #expect(termination == .endOfFile)
        #expect(recorder.chunkCount == 1)
        #expect(recorder.endOfFileCount == 1)
        #expect(recorder.readFailureCount == 0)
    }

    @Test
    func drainRoutesReadFailureToOnlyTheFailureHandlerOnce() async {
        let recorder = HandlerRecorder()

        let termination = await MCPStreamPump.drain(
            fileDescriptor: -1,
            handlers: MCPStreamPumpHandlers(
                onChunk: { _ in recorder.recordChunk() },
                onEndOfFile: { recorder.recordEndOfFile() },
                onReadFailure: { _ in recorder.recordReadFailure() }
            )
        )

        #expect(termination == .failure(.EBADF))
        #expect(recorder.chunkCount == 0)
        #expect(recorder.endOfFileCount == 0)
        #expect(recorder.readFailureCount == 1)
    }

    @Test
    func drainStaysSilentForCancellation() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let recorder = HandlerRecorder()
        let enteredLoop = Mutex<Bool>(false)

        let task = Task {
            await MCPStreamPump.drain(
                fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
                handlers: MCPStreamPumpHandlers(
                    onChunk: { _ in recorder.recordChunk() },
                    shouldStop: {
                        enteredLoop.withLock { $0 = true }
                        return false
                    },
                    onEndOfFile: { recorder.recordEndOfFile() },
                    onReadFailure: { _ in recorder.recordReadFailure() }
                )
            )
        }

        // Cancel only after the pump has entered its loop, so the assertion
        // exercises the mid-flight cancellation path rather than a task which
        // never ran. `shouldStop` runs before the first read, so this wait is
        // deterministic and does not depend on read timing.
        while !enteredLoop.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()

        #expect(await task.value == .cancelled)
        #expect(recorder.chunkCount == 0)
        #expect(recorder.endOfFileCount == 0)
        #expect(recorder.readFailureCount == 0)
        pipe.fileHandleForWriting.closeFile()
    }

    @Test
    func drainStaysSilentForPolicyStop() async throws {
        let pipe = Pipe()
        try MCPClient.makeNonBlocking(pipe.fileHandleForReading)
        let recorder = HandlerRecorder()

        let termination = await MCPStreamPump.drain(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            handlers: MCPStreamPumpHandlers(
                onChunk: { _ in recorder.recordChunk() },
                shouldStop: { true },
                onEndOfFile: { recorder.recordEndOfFile() },
                onReadFailure: { _ in recorder.recordReadFailure() }
            )
        )

        #expect(termination == .stopped)
        #expect(recorder.chunkCount == 0)
        #expect(recorder.endOfFileCount == 0)
        #expect(recorder.readFailureCount == 0)
        pipe.fileHandleForWriting.closeFile()
    }
}
#endif
