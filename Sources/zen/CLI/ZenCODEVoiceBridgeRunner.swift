import Foundation
import Dispatch
import Synchronization
import ZenCODECore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Composition root for a single voice call, separate from configuration setup and agent runners.
enum ZenCODEVoiceBridgeRunner {
    static func shouldRun(arguments: [String]) -> Bool { arguments.dropFirst().first == "--voice-bridge" }
    static func run(arguments: [String]) async -> Int32 {
        guard Array(arguments.dropFirst()) == ["--voice-bridge"], isatty(STDIN_FILENO) == 0, isatty(STDOUT_FILENO) == 0 else { return 2 }
        var inputInfo = stat(), outputInfo = stat()
        guard fstat(STDIN_FILENO, &inputInfo) == 0, fstat(STDOUT_FILENO, &outputInfo) == 0,
              inputInfo.st_mode & S_IFMT == S_IFIFO, outputInfo.st_mode & S_IFMT == S_IFIFO else { return 2 }
        signal(SIGPIPE, SIG_IGN)
        let stop = Mutex(false)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { stop.withLock { $0 = true } }
            source.resume(); return source
        }
        defer { signals.forEach { $0.cancel() } }
        guard fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK) != -1,
              fcntl(STDOUT_FILENO, F_SETFL, fcntl(STDOUT_FILENO, F_GETFL) | O_NONBLOCK) != -1 else { return 2 }
        let writer = VoiceBridgeStdout()
        let voice = ChatGPTVoiceBridge { event in try await writer.write(event) }
        var framer = VoiceBridgeFramer()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var code: Int32 = 0
        do {
            try await voice.ready()
            while !stop.withLock({ $0 }), !(await writer.finished) {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count > 0 {
                    for line in try framer.append(Data(buffer.prefix(count))) {
                        let command = try VoiceBridgeCommand.decode(line)
                        try await voice.handle(command)
                        if command.command == "close" { break }
                    }
                } else if count == 0 { try framer.finish(); break }
                else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { throw VoiceBridgeFailure.disconnected }
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            code = 1
            try? await writer.write(.init(type: "error", code: "invalid_voice_protocol"))
        }
        await voice.close()
        return code
    }
}
actor VoiceBridgeStdout {
    private let fileDescriptor: Int32
    init(fileDescriptor: Int32 = STDOUT_FILENO) { self.fileDescriptor = fileDescriptor }
    private(set) var finished = false
    private var tail: Task<Void, Error>?
    func write(_ event: VoiceBridgeEvent) async throws {
        var bytes = try JSONEncoder().encode(event); bytes.append(10)
        guard bytes.count <= VoiceBridgeCommand.maximumLineBytes else { throw VoiceBridgeFailure.overflow }
        let previous = tail
        let descriptor = fileDescriptor
        let task = Task {
            try await previous?.value
            try await Self.writeBytes(bytes, descriptor: descriptor)
        }
        tail = task
        do {
            try await task.value
            if event.type == "closed" { finished = true }
        } catch { finished = true; throw error }
    }
    private static func writeBytes(_ data: Data, descriptor: Int32) async throws {
        var bytes = data
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !bytes.isEmpty {
            let count = bytes.withUnsafeBytes { raw in
                #if canImport(Darwin)
                Darwin.write(descriptor, raw.baseAddress, raw.count)
                #else
                Glibc.write(descriptor, raw.baseAddress, raw.count)
                #endif
            }
            if count > 0 { bytes.removeFirst(count) }
            else if count < 0, errno == EINTR { continue }
            else if count < 0, (errno == EAGAIN || errno == EWOULDBLOCK), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            else { throw VoiceBridgeFailure.disconnected }
        }
    }
}
