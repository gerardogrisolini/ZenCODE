import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Shared POSIX process-tree signalling used by foreground feature processes and
/// long-lived direct jobs. Linux prefers process groups; macOS additionally
/// snapshots descendants because Foundation does not consistently isolate a
/// launched `Process` into its own group.
public enum FeatureProcessTreeSupervisor {
    /// Terminates one captured process tree with a single shared TERM→KILL
    /// escalation. Descendants are snapshotted before TERM because an exiting
    /// root may re-parent a TERM-ignoring child before the grace period ends.
    public static func terminateAndEscalate(
        _ process: Process,
        graceNanoseconds: UInt64 = 1_000_000_000
    ) async {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let processGroupLeader = isProcessGroupLeader(process)
        #if os(macOS)
        let capturedDescendants = processGroupLeader ? [] : descendantPIDs(of: pid)
        #endif

        send(SIGTERM, to: process, processGroupLeader: processGroupLeader)
        let deadline = ContinuousClock.now + .nanoseconds(Int64(clamping: graceNanoseconds))
        while process.isRunning, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        #if os(macOS)
        for descendantPID in capturedDescendants.reversed() {
            _ = Darwin.kill(descendantPID, SIGKILL)
        }
        #endif
        if process.isRunning {
            send(SIGKILL, to: process, processGroupLeader: processGroupLeader)
        }
    }

    public static func isProcessGroupLeader(_ process: Process) -> Bool {
        let pid = process.processIdentifier
        guard pid > 0 else { return false }
        #if os(Linux)
        return Glibc.getpgid(pid) == pid
        #elseif os(macOS)
        return Darwin.getpgid(pid) == pid
        #else
        return false
        #endif
    }

    public static func send(
        _ signal: Int32,
        to process: Process,
        processGroupLeader: Bool
    ) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        let target = processGroupLeader ? -pid : pid
        #if os(Linux)
        _ = Glibc.kill(target, signal)
        #elseif os(macOS)
        if !processGroupLeader {
            for descendantPID in descendantPIDs(of: pid).reversed() {
                _ = Darwin.kill(descendantPID, signal)
            }
        }
        _ = Darwin.kill(target, signal)
        #endif
    }

    #if os(macOS)
    private static func descendantPIDs(of rootPID: Int32) -> [Int32] {
        var result: [Int32] = []
        var pending = [rootPID]
        while let parentPID = pending.popLast() {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-P", String(parentPID)]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                continue
            }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            let children = String(decoding: output, as: UTF8.self)
                .split(whereSeparator: \.isNewline)
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                .filter { $0 > 0 }
            result.append(contentsOf: children)
            pending.append(contentsOf: children)
        }
        return result
    }
    #endif
}
