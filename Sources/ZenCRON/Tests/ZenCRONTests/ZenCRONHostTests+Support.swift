//
//  ZenCRONHostTests+Support.swift
//  ZenCODE
//
//  Fake zen scripts and process plumbing for the ZenCRON host tests: the
//  fixture on disk, the signal-masked launcher and the host process wrapper.
//

import Foundation
import Synchronization
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Fake zen scripts

extension ZenCRONHostTests {
    /// Records argv0, the argument list, stdin and one environment variable,
    /// writes to both output streams, then exits with `exitCode`.
    static func recordingZen(exitCode: Int32) -> String {
        """
        #!/bin/sh
        dir="${0%/*}"
        {
            echo "argv0=$0"
            echo "argc=$#"
            for arg in "$@"; do
                printf '[%s]\\n' "$arg"
            done
        } > "$dir/args.txt"
        cat > "$dir/stdin.txt"
        echo "to-stdout"
        echo "to-stderr" >&2
        echo "env=$ZENCRON_TEST_VALUE"
        echo "empty=${ZENCRON_TEST_EMPTY+set}"
        exit \(exitCode)
        """
    }

    /// Runs the host and waits for it. By default it is the fixture's host with
    /// the fixture's cron-like environment.
    static func run(
        _ fixture: HostFixture,
        executable: URL? = nil,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: Data? = nil
    ) async throws -> HostRun {
        let host = try await HostProcess(
            executable: executable ?? fixture.hostURL,
            arguments: arguments,
            environment: environment ?? fixture.environment(),
            standardInput: standardInput,
            outputDirectory: fixture.root
        )
        try await host.waitForExit(timeout: timeout)
        return host.result()
    }

    /// Polls until `url` exists. Returns false if the host exits first or the
    /// timeout elapses.
    static func waitForFile(_ url: URL, host: HostProcess) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
                return true
            }
            if !host.process.isRunning {
                return false
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}

// MARK: - Process plumbing

private struct HostTestError: Error, CustomStringConvertible {
    let description: String
}

struct HostRun {
    let status: Int32
    let reason: Process.TerminationReason
    let standardOutput: String
    let standardError: String
}

/// A temporary directory (named with a UUID) laid out the way ZenCRON is
/// installed: the compiled `ZenCRON` copied to a directory of its own, and an
/// optional fake `zen` in a separate directory that the default `PATH` lists.
/// Nothing is next to the host.
struct HostFixture {
    let root: URL
    /// The copy of the compiled host, alone in its directory.
    let hostURL: URL
    /// The directory of the fake `zen`. Fake zen scripts write the files they
    /// record next to themselves, so `url(_:)` and `read(_:)` refer to it.
    let zenDirectory: URL

    var zenPath: String {
        zenDirectory.appendingPathComponent("zen").path
    }

    /// A cron-like `PATH`: the directory of the fake `zen`, then the system ones.
    var path: String {
        "\(zenDirectory.path):/usr/bin:/bin"
    }

    /// The environment of a launched process: only `PATH` (the default one
    /// unless `path` is given) plus `extra`, no inherited test-runner variables.
    func environment(path: String? = nil, extra: [String: String] = [:]) -> [String: String] {
        ["PATH": path ?? self.path].merging(extra) { _, new in new }
    }

    static func make(zen: String?, zenPermissions: Int = 0o755) throws -> HostFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencron-host-\(UUID().uuidString)", isDirectory: true)
        let hostDirectory = root.appendingPathComponent("host", isDirectory: true)
        let zenDirectory = root.appendingPathComponent("zen-bin", isDirectory: true)

        let hostURL = hostDirectory.appendingPathComponent("ZenCRON")
        do {
            try FileManager.default.createDirectory(at: hostDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: zenDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: try locateCompiledHost(), to: hostURL)
            if let zen {
                try install(script: zen, named: "zen", permissions: zenPermissions, in: zenDirectory)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        return HostFixture(root: root, hostURL: hostURL, zenDirectory: zenDirectory)
    }

    static func install(script: String, named name: String, permissions: Int = 0o755, in directory: URL) throws {
        let url = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    /// Creates an extra directory under the fixture root.
    func makeDirectory(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func url(_ name: String) -> URL {
        zenDirectory.appendingPathComponent(name)
    }

    func read(_ name: String) -> String? {
        try? String(contentsOf: url(name), encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// SwiftPM places executable products next to the test bundle (or next to
    /// the test executable on Linux). Resolve that product directory from the
    /// test bundle path supplied to `swiftpm-testing-helper` instead of asking
    /// SwiftPM to inspect its build directory while tests are running; that
    /// command would contend for SwiftPM's build-directory lock.
    private static func locateCompiledHost() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let arguments = CommandLine.arguments
        var executableURLs: [URL] = []

        func appendExecutableURL(from path: String) {
            guard !path.isEmpty else { return }
            executableURLs.append(
                URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
            )
        }

        for (index, argument) in arguments.enumerated() {
            if argument == "--test-bundle-path", arguments.indices.contains(index + 1) {
                appendExecutableURL(from: arguments[index + 1])
            } else if argument.hasPrefix("--test-bundle-path=") {
                appendExecutableURL(from: String(argument.dropFirst("--test-bundle-path=".count)))
            } else if argument.contains(".xctest") {
                appendExecutableURL(from: argument)
            }
        }
        if let executableURL = Bundle.main.executableURL {
            executableURLs.append(executableURL.standardizedFileURL)
        }
        if let argument = arguments.first {
            appendExecutableURL(from: argument)
        }

        var searchedDirectories: [URL] = []

        func appendSearchDirectory(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard !searchedDirectories.contains(where: { $0.path == standardized.path }) else { return }
            searchedDirectories.append(standardized)
        }

        for executableURL in executableURLs {
            appendSearchDirectory(productDirectory(for: executableURL))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendSearchDirectory(productDirectory(for: bundle.bundleURL))
            if let executableURL = bundle.executableURL {
                appendSearchDirectory(productDirectory(for: executableURL))
            }
        }
        for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
            guard let value = ProcessInfo.processInfo.environment[key] else { continue }
            for path in value.split(separator: ":") where !path.isEmpty {
                appendSearchDirectory(URL(fileURLWithPath: String(path)))
            }
        }

        for directory in searchedDirectories {
            let candidate = directory.appendingPathComponent("ZenCRON")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        let searched = searchedDirectories.map(\.path).joined(separator: ", ")
        throw HostTestError(description: "ZenCRON executable not found (searched in: \(searched))")
    }

    private static func productDirectory(for executableURL: URL) -> URL {
        let components = executableURL.standardizedFileURL.path.split(separator: "/")
        if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
            let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
            return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent()
    }
}

/// Set by `terminationHandler` once the child has been reaped.
private final class ExitFlag: Sendable {
    private let state = Mutex(false)

    func set() {
        state.withLock { $0 = true }
    }

    var isSet: Bool {
        state.withLock { $0 }
    }
}

/// Carries a `Process` to the launcher thread. Only one thread touches the
/// process at a time: the awaiting task does not use it until the launcher
/// thread has resumed the continuation, which is the synchronisation point.
private struct ProcessHandoff: @unchecked Sendable {
    let process: Process
}

/// Launches a `Process` from a dedicated thread whose signal mask is set
/// first, instead of from whatever thread the caller happens to run on.
///
/// This is needed because, on Linux, `Foundation.Process.run()` gives the
/// child the mask of BLOCKED signals of the calling thread. A Swift task runs
/// on a libdispatch worker thread, and a probe showed such a worker blocking
/// SIGTERM, SIGINT, SIGHUP and SIGQUIT (`SigBlk: fffffffe3bfbea27`), while the
/// main thread gave the child `SigBlk: 0`. ZenCRON is transparent and passes to
/// zen the mask it received, so with SIGTERM blocked neither a `kill -s TERM`
/// by zen on itself nor the forwarding of SIGTERM would work. Production is
/// different: cron starts ZenCRON with an empty mask. The harness reproduces
/// that by clearing the mask on the launcher thread (or by blocking just the
/// signals a test asks for). The same path is used on macOS and Linux.
private enum SignalMaskedLauncher {
    /// Runs `process` from a new thread whose signal mask blocks exactly
    /// `blockedSignals`, and resumes with the outcome of `run()`, errors
    /// included. The calling task is suspended, not blocked, while the thread
    /// works, so the cooperative pool stays free.
    static func run(_ process: Process, blockedSignals: [Int32]) async throws {
        let handoff = ProcessHandoff(process: process)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let thread = Thread {
                do {
                    try setSignalMask(blocking: blockedSignals)
                    try handoff.process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
            thread.name = "zencron-test-launcher"
            thread.start()
        }
    }

    /// Replaces the signal mask of the calling thread.
    private static func setSignalMask(blocking signals: [Int32]) throws {
        var mask = sigset_t()
        sigemptyset(&mask)
        for signalNumber in signals {
            sigaddset(&mask, signalNumber)
        }
        let status = pthread_sigmask(SIG_SETMASK, &mask, nil)
        guard status == 0 else {
            throw HostTestError(description: "pthread_sigmask failed: \(String(cString: strerror(status)))")
        }
    }
}

/// A launched host. Output goes to files rather than pipes so a chatty or
/// stuck child can never deadlock the test, and standard input is a pipe (as
/// cron provides one) that is filled and closed right after launch.
///
/// The host is started by `SignalMaskedLauncher`, with an empty signal mask
/// as under cron unless `blockedSignals` says otherwise.
///
/// Exit is observed through `terminationHandler`, never through
/// `Process.waitUntilExit()`: on Darwin that call waits on the run loop of the
/// calling thread and can park forever on a cooperative-pool thread when the
/// machine is busy, even though the child is long gone.
final class HostProcess {
    let process = Process()
    private let outputURL: URL
    private let errorURL: URL
    private let exitFlag = ExitFlag()

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        standardInput: Data?,
        outputDirectory: URL,
        blockedSignals: [Int32] = []
    ) async throws {
        outputURL = outputDirectory.appendingPathComponent("host-stdout-\(UUID().uuidString)")
        errorURL = outputDirectory.appendingPathComponent("host-stderr-\(UUID().uuidString)")
        let fileManager = FileManager.default
        // On Linux `createFile` is not discardable: check it instead of ignoring it.
        for url in [outputURL, errorURL] {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw HostTestError(description: "cannot create \(url.path)")
            }
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let inputPipe = Pipe()
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = outputDirectory
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = standardInput == nil ? FileHandle.nullDevice : inputPipe
        process.terminationHandler = { [exitFlag] _ in
            exitFlag.set()
        }
        try await SignalMaskedLauncher.run(process, blockedSignals: blockedSignals)

        // The parent keeps the read end open until the data is written, so the
        // write cannot hit EPIPE even if the child never reads.
        if let standardInput {
            try inputPipe.fileHandleForWriting.write(contentsOf: standardInput)
        }
        try inputPipe.fileHandleForWriting.close()
        try inputPipe.fileHandleForReading.close()
    }

    deinit {
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Waits for the host to exit; a host that outlives `timeout` is killed.
    func waitForExit(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !exitFlag.isSet {
            if Date() >= deadline {
                kill(process.processIdentifier, SIGKILL)
                // Bounded wait: the kill cannot be refused, but never park here.
                let killDeadline = Date().addingTimeInterval(5)
                while !exitFlag.isSet, Date() < killDeadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw HostTestError(description: "ZenCRON did not exit within \(timeout) seconds")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func result() -> HostRun {
        HostRun(
            status: process.terminationStatus,
            reason: process.terminationReason,
            standardOutput: (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "",
            standardError: (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        )
    }
}
