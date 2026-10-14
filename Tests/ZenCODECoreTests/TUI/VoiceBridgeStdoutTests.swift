import Foundation
import Testing
@testable import zen
@testable import ZenCODECore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct VoiceBridgeStdoutTests {
    @Test func voiceFlagDoesNotCapturePromptText() {
        #expect(ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen", "--voice-bridge"]))
        #expect(ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen", "--voice-bridge", "--acp"])) // strict runner rejects the combination
        #expect(!ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen", "-p", "--voice-bridge"]))
        #expect(!ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen", "--prompt", "--voice-bridge"]))
        #expect(!ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen", "--jsonl", "--voice-bridge"]))
        #expect(!ZenCODEVoiceBridgeRunner.shouldRun(arguments: ["zen"]))
    }
    @Test func boundedBackpressureDoesNotHoldCleanupForever() async throws {
        let pipe = Pipe()
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        let fd = pipe.fileHandleForWriting.fileDescriptor
        #expect(fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1)
        // Fill the pipe without consuming it; no real credentials or provider data.
        let padding = [UInt8](repeating: 65, count: 4096)
        while padding.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) > 0 {}
        let output = VoiceBridgeStdout(fileDescriptor: fd)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await output.write(.init(type: "ready")) }
        #expect(ContinuousClock.now - start < .seconds(7))
        #expect(await output.finished)
    }
}
