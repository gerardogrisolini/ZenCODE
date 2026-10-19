//
//  SupportDirectoryArchive+Process.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension SupportDirectoryArchive {
    /// Bytes read from stdout/stderr of a tar process in one chunk.
    static let processChunkSize = 1 << 16

    /// Resolves the tar executable from a fixed search path (deterministic when
    /// `PATH` is empty or attacker-controlled) without spawning a shell.
    static func locateTarExecutable(
        fileManager: FileManager
    ) -> URL? {
        let candidates = [
            "/usr/bin/tar",
            "/bin/tar",
            "/usr/local/bin/tar",
            "/opt/homebrew/bin/tar"
        ]
        for candidate in candidates where fileManager.isExecutableFile(
            atPath: candidate
        ) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }

    /// Runs a tar invocation (paths are positional arguments, never a shell) and
    /// returns stdout; a nonzero exit throws `archiveNotReadable` with stderr.
    static func runTar(
        _ arguments: [String],
        standardInput: Data? = nil,
        fileManager: FileManager
    ) throws -> Data {
        var collected = Data()
        try runTar(
            arguments,
            standardInput: standardInput,
            fileManager: fileManager
        ) { collected.append($0) }
        return collected
    }

    /// Drains a pipe on a dedicated thread, retaining only the first bytes, so a
    /// chatty child can neither block on stderr nor force unbounded buffering.
    final class BoundedPipeDrain: @unchecked Sendable {
        private let lock = NSLock()
        private let finished = DispatchSemaphore(value: 0)
        private var retained = Data()
        private let limit: Int

        init(handle: FileHandle, limit: Int) {
            self.limit = limit
            // A dedicated thread (not the shared dispatch pool) so draining
            // can never be starved when callers block pool threads.
            let thread = Thread { [self] in
                while let chunk = try? handle.read(upToCount: 16 * 1024),
                      !chunk.isEmpty {
                    lock.lock()
                    if retained.count < limit {
                        retained.append(chunk.prefix(limit - retained.count))
                    }
                    lock.unlock()
                }
                finished.signal()
            }
            thread.stackSize = 256 * 1024
            thread.start()
        }

        /// Waits for EOF on the pipe and returns the retained prefix.
        func finish() -> Data {
            finished.wait()
            lock.lock()
            defer { lock.unlock() }
            return retained
        }
    }

    /// Streaming variant: stdout chunks go to `sink` as they arrive; stderr is
    /// drained independently so neither pipe stalls the child. If `sink` throws
    /// the child is terminated and reaped before the error propagates.
    static func runTar(
        _ arguments: [String],
        standardInput: Data? = nil,
        fileManager: FileManager,
        stdoutSink sink: (Data) throws -> Void
    ) throws {
        guard let executableURL = locateTarExecutable(fileManager: fileManager)
        else {
            throw SupportDirectoryArchiveError.tarUnavailable("no executable tar was found in the standard system paths")
        }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError

        if let standardInput {
            let inputPipe = Pipe()
            process.standardInput = inputPipe
            try process.run()
            // Feed the list while the child consumes it so large lists never
            // block on a full pipe buffer.
            do {
                try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
                try inputPipe.fileHandleForWriting.close()
            } catch {
                // A write failure (e.g. the child exited early) surfaces
                // through the child's exit status below.
            }
        } else {
            try process.run()
        }

        let stdoutHandle = standardOutput.fileHandleForReading
        let stderrHandle = standardError.fileHandleForReading
        let errorDrain = BoundedPipeDrain(handle: stderrHandle, limit: 2048)
        var sinkError: (any Error)?
        do {
            while let chunk = try stdoutHandle.read(upToCount: processChunkSize),
                  !chunk.isEmpty {
                try sink(chunk)
            }
        } catch {
            sinkError = error
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit()
        let errorCollected = errorDrain.finish()
        try? stdoutHandle.close()
        try? stderrHandle.close()
        if let sinkError { throw sinkError }

        guard process.terminationStatus == 0 else {
            let reason = String(
                decoding: errorCollected.prefix(2048),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SupportDirectoryArchiveError.archiveNotReadable(
                reason.isEmpty ? "tar exited with status \(process.terminationStatus)" : reason
            )
        }
    }
}
