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
}
#endif
