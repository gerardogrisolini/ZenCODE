//
//  ZenAppProcessLauncher.swift
//  ZenCODE
//

#if os(macOS)
import Darwin
import Foundation

/// Starts the installed ZenCODE app as a detached process, so that `zen --ui`
/// can exit and give the terminal back while the app keeps running.
///
/// The app is spawned with `posix_spawn` in a session of its own
/// (`POSIX_SPAWN_SETSID`), so closing the terminal or pressing Ctrl+C in it
/// never reaches it; with an empty signal mask and every signal at its default
/// disposition, whatever `zen` blocked or ignored; and with no descriptor of
/// `zen` but the three standard ones (`POSIX_SPAWN_CLOEXEC_DEFAULT`): standard
/// input from `/dev/null`, standard output and error to the log file, which
/// only the user can read. When `zen` exits, launchd adopts it.
enum ZenAppProcessLauncher {
    /// Variables of `zen`'s environment the app does not inherit:
    /// `ZENCODE_AGENT_MODE` selects a mode of `zen`, not of the app.
    static let removedEnvironmentKeys: Set<String> = ["ZENCODE_AGENT_MODE"]

    /// The mode of the log file: the app's output can quote the user's work.
    static let logFilePermissions: mode_t = 0o600

    /// How long the app is watched after it started: an app that exits within
    /// this time is reported as a failure.
    static let defaultStartupObservation: Duration = .milliseconds(1_500)
    /// How often the app is checked while it is watched.
    static let defaultPollInterval: Duration = .milliseconds(100)
    /// Lines of the log shown when the app exits right after starting.
    static let logTailLineLimit = 20

    /// Why the app did not start.
    enum LaunchError: LocalizedError, Equatable {
        case spawnFailed(path: String, reason: String)
        case exitedRightAfterStarting(termination: String, logPath: String, output: String)

        var errorDescription: String? {
            switch self {
            case let .spawnFailed(path, reason):
                return "The ZenCODE app at \(path) could not be started: \(reason)"
            case let .exitedRightAfterStarting(termination, logPath, output):
                let text = "The ZenCODE app exited right after starting (\(termination)). "
                    + "Its output is in \(logPath):"
                return "\(text)\n\(output.isEmpty ? "(no output)" : output)"
            }
        }
    }

    /// The environment of the app: `environment` without
    /// `removedEnvironmentKeys`.
    static func childEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { !removedEnvironmentKeys.contains($0.key) }
    }

    /// How a child ended, from its `waitpid` status. The `WIF*` macros are not
    /// importable, so the classic status layout is decoded here.
    static func terminationDescription(waitStatus status: Int32) -> String {
        let signalNumber = status & 0x7f
        if signalNumber == 0 {
            return "exit status \((status >> 8) & 0xff)"
        }
        return "terminated by signal \(signalNumber)"
    }

    /// Starts `executable` with `[executable path] + arguments` in the current
    /// working directory, then watches it for `startupObservation`. The log
    /// is created with `logFilePermissions`, and an existing one gets them
    /// before the app starts (truncating it keeps its old mode).
    ///
    /// - Returns: The process identifier of the running app.
    /// - Throws: `LaunchError.spawnFailed` when it cannot be started, and
    ///   `LaunchError.exitedRightAfterStarting` (with the end of the log) when
    ///   it exits while it is watched.
    static func launch(
        executable: URL,
        arguments: [String],
        logFile: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startupObservation: Duration = defaultStartupObservation,
        pollInterval: Duration = defaultPollInterval
    ) async throws -> pid_t {
        do {
            try FileManager.default.createDirectory(
                at: logFile.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw LaunchError.spawnFailed(
                path: executable.path,
                reason: "the log directory cannot be created: \(error.localizedDescription)"
            )
        }
        if chmod(logFile.path, logFilePermissions) != 0 {
            let code = errno
            if code != ENOENT {
                throw LaunchError.spawnFailed(
                    path: executable.path,
                    reason: "the log file \(logFile.path) cannot be made private: \(String(cString: strerror(code)))"
                )
            }
        }
        let pid = try spawn(
            executable: executable,
            arguments: arguments,
            logFile: logFile,
            environment: childEnvironment(environment)
        )

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: startupObservation)
        while true {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                throw LaunchError.exitedRightAfterStarting(
                    termination: terminationDescription(waitStatus: status),
                    logPath: logFile.path,
                    output: logTail(of: logFile)
                )
            }
            if waited == -1, errno != EINTR {
                // Nothing to wait for (already reaped elsewhere): stop watching.
                break
            }
            guard clock.now < deadline else { break }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                // Cancelled: the app is running; stop watching it.
                break
            }
        }
        return pid
    }

    /// The last `logTailLineLimit` lines of the log.
    static func logTail(of logFile: URL) -> String {
        guard let data = try? Data(contentsOf: logFile) else { return "" }
        return ZenAppInstallation.lastLines(
            of: String(decoding: data, as: UTF8.self),
            limit: logTailLineLimit
        )
    }

    // MARK: - posix_spawn

    private static func spawn(
        executable: URL,
        arguments: [String],
        logFile: URL,
        environment: [String: String]
    ) throws -> pid_t {
        func failure(_ status: Int32, _ step: String) -> LaunchError {
            .spawnFailed(path: executable.path, reason: "\(step): \(String(cString: strerror(status)))")
        }

        var attributes: posix_spawnattr_t? = nil
        var status = posix_spawnattr_init(&attributes)
        guard status == 0 else { throw failure(status, "posix_spawnattr_init") }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = POSIX_SPAWN_SETSID
            | POSIX_SPAWN_SETSIGDEF
            | POSIX_SPAWN_SETSIGMASK
            | POSIX_SPAWN_CLOEXEC_DEFAULT
        status = posix_spawnattr_setflags(&attributes, Int16(flags))
        guard status == 0 else { throw failure(status, "posix_spawnattr_setflags") }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        status = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        guard status == 0 else { throw failure(status, "posix_spawnattr_setsigmask") }

        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        status = posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        guard status == 0 else { throw failure(status, "posix_spawnattr_setsigdefault") }

        var fileActions: posix_spawn_file_actions_t? = nil
        status = posix_spawn_file_actions_init(&fileActions)
        guard status == 0 else { throw failure(status, "posix_spawn_file_actions_init") }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        status = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        guard status == 0 else { throw failure(status, "standard input") }
        status = posix_spawn_file_actions_addopen(
            &fileActions,
            STDOUT_FILENO,
            logFile.path,
            O_WRONLY | O_CREAT | O_TRUNC | O_APPEND,
            logFilePermissions
        )
        guard status == 0 else { throw failure(status, "standard output") }
        status = posix_spawn_file_actions_adddup2(&fileActions, STDOUT_FILENO, STDERR_FILENO)
        guard status == 0 else { throw failure(status, "standard error") }

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = environment
            .map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        status = posix_spawn(&pid, executable.path, &fileActions, &attributes, argv, envp)
        guard status == 0 else { throw failure(status, "posix_spawn") }
        return pid
    }
}
#endif
