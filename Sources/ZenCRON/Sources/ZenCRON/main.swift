// ZenCRON: the stable host that cron runs instead of `zen`.
//
// Contract
// - cron runs `ZenCRON <zen arguments>` by absolute path (it lives in its own
//   directory, not next to `zen`). ZenCRON locates `zen` on the `PATH` it
//   receives, runs it with exactly the same arguments, environment, standard
//   descriptors and process group, waits for it, and ends the same way it did:
//   with its exit code, or by dying from the same signal.
// - Where `zen` is searched: the `PATH` of the environment, which for cron is
//   the `PATH=` line of the ZenCODE block of the crontab (usually
//   `/usr/local/bin:/usr/bin:/bin`); an unset `PATH` counts as empty. Entries
//   are separated by `:`. Empty and relative entries are ignored, because they
//   would depend on the working directory of the job instead of on a fixed
//   location. Trailing slashes are removed from an entry (the entry `/` gives
//   `/zen`). The first `<entry>/zen` that `access(X_OK)` accepts wins. `zen`
//   receives that absolute path as its `argv[0]`.
// - That rule is deliberately the same as `ZenCronJobCommand.locateZen(onPath:)`
//   in ZenCODECore, which `/cron add` uses to check that the `PATH` it writes in
//   the crontab finds `zen`: the `zen` accepted when the job is scheduled is the
//   one this host runs. Change both together, or neither.
// - If no `zen` is found, ZenCRON writes `ZenCRON: no executable zen in
//   PATH=<value>` to standard error and exits with 127.
// - ZenCRON SPAWNS `zen`; it never `exec`s it. On macOS the privacy (TCC)
//   permissions of a cron job are attributed to the first non-system program
//   cron starts, and they stay with it for all of its descendants. `zen` is
//   only ad-hoc signed, so its identity changes with every installation and
//   the prompts would come back; ZenCRON is the stable identity. After an
//   `exec`, TCC would evaluate `zen` again and the whole point would be lost.
// - The binary must stay byte-identical across installations (installers
//   replace it only when its host version changes), so it is deliberately
//   minimal: no dependencies, not even Foundation.
// - `--zencron-version` as the only argument prints `ZenCRON <hostVersion>` and
//   exits without looking for `zen`; installers use it to compare versions.
//   Every other argument list, even an empty one, is passed to `zen` verbatim.
// - Increase `hostVersion` ONLY when this host's behaviour changes. Every new
//   version is a new binary for macOS, which asks for every permission again.
// - Termination signals are forwarded to `zen`. ZenCRON never changes session
//   or process group: `zen` stays in the group of ZenCRON.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#else
#error("ZenCRON supports Darwin, Glibc and Musl only")
#endif

enum Host {
    /// Version of the host's behaviour. See the contract above before changing it.
    static let hostVersion = 1

    /// Signals forwarded to `zen`.
    static let forwardedSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP, SIGQUIT]

    /// Child PID read by the signal handler. It is written before the forwarded
    /// signals are unblocked, so the handler never observes a stale value.
    nonisolated(unsafe) static var childPID: pid_t = 0

    static func run() -> Never {
        let argumentCount = Int(CommandLine.argc)
        let argv = CommandLine.unsafeArgv

        if argumentCount == 2,
           let only = argv[1],
           strcmp(only, "--zencron-version") == 0 {
            writeAll(STDOUT_FILENO, Array("ZenCRON \(hostVersion)\n".utf8))
            exit(0)
        }

        let path = environmentPath()
        guard let zenPath = locateZen(onPath: path) else {
            var message = Array("ZenCRON: no executable zen in PATH=".utf8)
            message.append(contentsOf: path.map { UInt8(truncatingIfNeeded: $0) })
            message.append(UInt8(ascii: "\n"))
            fail(bytes: message)
        }

        // The child's argv is the absolute path of `zen` followed by the
        // original argument pointers, so non-UTF-8 bytes pass through intact.
        var childArguments: [UnsafeMutablePointer<CChar>?] = [zenPath]
        if argumentCount > 1 {
            for index in 1..<argumentCount {
                childArguments.append(argv[index])
            }
        }
        childArguments.append(nil)

        // Block the forwarded signals before spawning so that none can arrive
        // before the child PID is known. The child still gets the ORIGINAL mask.
        var forwarded = sigset_t()
        sigemptyset(&forwarded)
        for signalNumber in forwardedSignals {
            sigaddset(&forwarded, signalNumber)
        }
        var originalMask = sigset_t()
        sigemptyset(&originalMask)
        if sigprocmask(SIG_BLOCK, &forwarded, &originalMask) != 0 {
            fail("ZenCRON: cannot block signals: \(describe(errno))\n")
        }

        var spawnedPID: pid_t = 0
        let spawnStatus = spawn(
            zenPath,
            arguments: childArguments,
            childSignalMask: &originalMask,
            childPID: &spawnedPID
        )
        if spawnStatus != 0 {
            fail("ZenCRON: cannot run \(String(cString: zenPath)): \(describe(spawnStatus))\n")
        }

        childPID = spawnedPID
        installForwardingHandlers()
        // Back to the original mask: pending forwarded signals are delivered now.
        sigprocmask(SIG_SETMASK, &originalMask, nil)

        exitLikeChild(status: waitForChild(spawnedPID))
    }

    // MARK: - Locating zen

    /// The bytes of the `PATH` environment variable, without the terminating
    /// NUL; empty when it is not set.
    static func environmentPath() -> [CChar] {
        guard let value = getenv("PATH") else {
            return []
        }
        return Array(UnsafeBufferPointer(start: value, count: strlen(value)))
    }

    /// The first executable `zen` in the `:`-separated `path`, as a
    /// NUL-terminated C string that is intentionally never freed (the process
    /// is short-lived). The rule is the one of
    /// `ZenCronJobCommand.locateZen(onPath:)`, see the contract above; it works
    /// on bytes so any path bytes survive.
    static func locateZen(onPath path: [CChar]) -> UnsafeMutablePointer<CChar>? {
        let slash = CChar(UInt8(ascii: "/"))
        let colon = CChar(UInt8(ascii: ":"))
        for entry in path.split(separator: colon, omittingEmptySubsequences: true) {
            guard entry.first == slash else { continue }

            var directory = entry
            while directory.count > 1, directory.last == slash {
                directory = directory.dropLast()
            }

            // Only the entry "/" still ends with a slash here: it gives "/zen".
            var candidate = Array(directory)
            if candidate.last != slash {
                candidate.append(slash)
            }
            candidate.append(contentsOf: "zen".utf8CString)

            if access(candidate, X_OK) == 0 {
                guard let result = strdup(candidate) else {
                    fail("ZenCRON: out of memory\n")
                }
                return result
            }
        }
        return nil
    }

    // MARK: - Spawning

    /// Starts `path` with `posix_spawn`: inherited descriptors (no file
    /// actions), unchanged environment, no session or process-group change.
    /// Returns 0 or the error number reported by `posix_spawn`.
    static func spawn(
        _ path: UnsafeMutablePointer<CChar>,
        arguments: [UnsafeMutablePointer<CChar>?],
        childSignalMask: inout sigset_t,
        childPID: inout pid_t
    ) -> Int32 {
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t? = nil
        #else
        var attributes = posix_spawnattr_t()
        #endif
        var status = posix_spawnattr_init(&attributes)
        if status != 0 {
            return status
        }
        defer { posix_spawnattr_destroy(&attributes) }

        // Only the signal mask is set: the kernel resets caught signals on
        // exec, and ignored ones stay ignored.
        status = posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK))
        if status != 0 {
            return status
        }
        status = posix_spawnattr_setsigmask(&attributes, &childSignalMask)
        if status != 0 {
            return status
        }

        return posix_spawn(&childPID, path, nil, &attributes, arguments, environ)
    }

    // MARK: - Signals

    /// Installs the forwarding handler for each forwarded signal unless it was
    /// already ignored at startup (for example inherited from cron): an ignored
    /// signal stays ignored, as it is for the child that inherited it. The
    /// forwarded signals are blocked while this runs.
    static func installForwardingHandlers() {
        let handler: @convention(c) (Int32) -> Void = { signalNumber in
            let savedErrno = errno
            let pid = Host.childPID
            if pid > 0 {
                _ = kill(pid, signalNumber)
            }
            errno = savedErrno
        }
        let ignored = unsafeBitCast(SIG_IGN, to: Int.self)
        for signalNumber in forwardedSignals {
            let previous = unsafeBitCast(signal(signalNumber, handler), to: Int.self)
            if previous == ignored {
                signal(signalNumber, SIG_IGN)
            }
        }
    }

    // MARK: - Waiting and exiting

    /// Waits for the child, retrying on `EINTR`, and returns its wait status.
    static func waitForChild(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid {
                // The PID is free for reuse from now on: stop forwarding.
                childPID = 0
                return status
            }
            if result == -1, errno == EINTR {
                continue
            }
            fail("ZenCRON: waitpid failed: \(describe(errno))\n", status: 1)
        }
    }

    /// Mirrors the child's outcome. The `WIF*` macros are not importable, so the
    /// classic status layout (shared by Darwin, glibc and musl) is decoded here.
    static func exitLikeChild(status: Int32) -> Never {
        let terminationSignal = status & 0x7f
        if terminationSignal == 0 {
            exit((status >> 8) & 0xff)
        }

        // Killed by a signal: die from the same one with the default action.
        signal(terminationSignal, SIG_DFL)
        var unblock = sigset_t()
        sigemptyset(&unblock)
        sigaddset(&unblock, terminationSignal)
        sigprocmask(SIG_UNBLOCK, &unblock, nil)
        raise(terminationSignal)
        // Only reached if the signal did not terminate us.
        _exit(128 + terminationSignal)
    }

    // MARK: - Output

    static func describe(_ error: Int32) -> String {
        String(cString: strerror(error))
    }

    /// 127 is the conventional "cannot run the command" status.
    static func fail(_ message: String, status: Int32 = 127) -> Never {
        fail(bytes: Array(message.utf8), status: status)
    }

    /// Same as `fail(_:status:)` for a message that is not necessarily UTF-8.
    static func fail(bytes: [UInt8], status: Int32 = 127) -> Never {
        writeAll(STDERR_FILENO, bytes)
        exit(status)
    }

    /// Plain `write(2)` loop; avoids `stdio` and its C globals.
    static func writeAll(_ descriptor: Int32, _ bytes: [UInt8]) {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer in
                write(descriptor, buffer.baseAddress, buffer.count)
            }
            if written < 0 {
                if errno == EINTR { continue }
                return
            }
            offset += written
        }
    }
}

Host.run()
