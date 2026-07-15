//
//  DirectExecJobRuntime.swift
//  ZenCODE
//
//  Background job lifecycle for `local.exec` with background=true and the
//  `exec.job` management tool (poll/kill/list).
//

import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

public enum DirectExecJobError: LocalizedError {
    case unsupportedPlatform
    case tooManyJobs(limit: Int)
    case jobNotFound(String)
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Background jobs are not supported on this platform."
        case let .tooManyJobs(limit):
            return "Too many running background jobs (limit \(limit)). Kill one with exec.job {\"action\":\"kill\",\"id\":\"...\"} or wait for a job to finish."
        case let .jobNotFound(identifier):
            return "No background job matched '\(identifier)'. Use exec.job {\"action\":\"list\"} to see known jobs."
        case let .launchFailed(message):
            return "Failed to start background job: \(message)"
        }
    }
}

/// Accumulates interleaved stdout/stderr output for one background job.
/// Appended from pipe readability handlers (dispatch queues) and read from
/// the runtime actor, so access is lock-protected. Retains a bounded tail of
/// the transcript; earlier bytes are dropped but remain accounted for so poll
/// offsets stay stable.
final class DirectExecJobTranscript: @unchecked Sendable {
    struct Snapshot: Sendable {
        let text: String
        let nextOffset: Int
        let outputWasDropped: Bool
    }

    private let lock = NSLock()
    private var data = Data()
    private var droppedBytes = 0
    private let maxRetainedBytes: Int

    init(maxRetainedBytes: Int) {
        self.maxRetainedBytes = max(maxRetainedBytes, 1)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > maxRetainedBytes {
            let overflow = data.count - maxRetainedBytes
            data = Data(data.dropFirst(overflow))
            droppedBytes += overflow
        }
    }

    /// Returns the transcript text at or after `offset` (a byte offset into
    /// the job's full output), the next offset to poll from, and whether any
    /// requested bytes were already dropped from the retained tail.
    func read(from offset: Int) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let total = droppedBytes + data.count
        let clamped = min(max(offset, 0), total)
        let outputWasDropped = clamped < droppedBytes
        let localStart = max(clamped - droppedBytes, 0)
        let chunk = Data(data.dropFirst(localStart))
        return Snapshot(
            text: String(decoding: chunk, as: UTF8.self),
            nextOffset: total,
            outputWasDropped: outputWasDropped
        )
    }
}

/// Owns background shell jobs started by `local.exec` with background=true.
/// Job launch stays behind the `local.exec` authorization gate; `exec.job`
/// only manages processes that were already approved and started.
public actor DirectExecJobRuntime {
    public static let toolName = "exec.job"
    public static let defaultMaxRunningJobs = 8
    static let maxRetainedTranscriptBytes = 2_000_000
    static let maxRetainedFinishedJobs = 16

    public enum JobStatus: String, Sendable {
        case running
        case exited
        case killed
    }

    public static func isExecJobToolName(_ name: String) -> Bool {
        name == toolName
    }

#if os(macOS) || os(Linux)
    private final class Job {
        let id: String
        let command: String
        let workingDirectory: String
        let startedAt = Date()
        let process: Process
        let transcript: DirectExecJobTranscript
        var status: JobStatus = .running
        var exitCode: Int32?
        var finishedAt: Date?
        var killRequested = false
        var killReason: String?

        init(
            id: String,
            command: String,
            workingDirectory: String,
            process: Process,
            transcript: DirectExecJobTranscript
        ) {
            self.id = id
            self.command = command
            self.workingDirectory = workingDirectory
            self.process = process
            self.transcript = transcript
        }
    }

    private var jobsByID: [String: Job] = [:]
    private var jobOrder: [String] = []
    private var nextJobNumber = 1
    private let maxRunningJobs: Int

    public init(maxRunningJobs: Int = DirectExecJobRuntime.defaultMaxRunningJobs) {
        self.maxRunningJobs = max(maxRunningJobs, 1)
    }

    // MARK: - Launch

    /// Starts `command` as a background job and returns a rendered launch
    /// summary for the model. The caller is responsible for authorization.
    public func startBackgroundJob(
        command: String,
        shellPath: String,
        workingDirectory: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> String {
        let runningCount = jobsByID.values.filter { $0.status == .running }.count
        guard runningCount < maxRunningJobs else {
            throw DirectExecJobError.tooManyJobs(limit: maxRunningJobs)
        }

        let jobID = "job-\(nextJobNumber)"
        nextJobNumber += 1

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = workingDirectory
        if let environment {
            process.environment = environment
        }

        let transcript = DirectExecJobTranscript(
            maxRetainedBytes: Self.maxRetainedTranscriptBytes
        )
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        for handle in [stdoutPipe.fileHandleForReading, stderrPipe.fileHandleForReading] {
            handle.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                if chunk.isEmpty {
                    fileHandle.readabilityHandler = nil
                } else {
                    transcript.append(chunk)
                }
            }
        }

        process.terminationHandler = { [weak self] process in
            let exitCode = process.terminationStatus
            Task {
                await self?.markFinished(jobID: jobID, exitCode: exitCode)
            }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw DirectExecJobError.launchFailed(error.localizedDescription)
        }

        let job = Job(
            id: jobID,
            command: command,
            workingDirectory: workingDirectory.path,
            process: process,
            transcript: transcript
        )
        jobsByID[jobID] = job
        jobOrder.append(jobID)

        if let timeout, timeout > 0 {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self?.killIfRunning(jobID: jobID, reason: "timeout after \(Int(timeout))s")
            }
        }

        return """
        Started background job \(jobID) (pid \(process.processIdentifier)).
        command: \(command)
        working directory: \(workingDirectory.path)
        Use exec.job {"action":"poll","id":"\(jobID)"} to read incremental output and exec.job {"action":"kill","id":"\(jobID)"} to stop it.
        """
    }

    // MARK: - exec.job dispatch

    public func execute(toolCall: DirectAgentToolCall) async throws -> String {
        let arguments = toolCall.argumentsObject
        let action = arguments.string("action")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch action {
        case "poll", "status", "output":
            let jobID = try requiredJobID(in: arguments)
            let offset = arguments.int("offset") ?? 0
            return try poll(jobID: jobID, offset: offset)
        case "kill", "stop", "terminate":
            let jobID = try requiredJobID(in: arguments)
            return try await kill(jobID: jobID)
        case "list", nil, "":
            return list()
        default:
            throw DirectTodoTaskRuntimeError.invalidArgument(
                "action '\(action ?? "")' (expected poll, kill, or list)"
            )
        }
    }

    // MARK: - Poll / Kill / List

    public func poll(jobID: String, offset: Int) throws -> String {
        guard let job = jobsByID[jobID] else {
            throw DirectExecJobError.jobNotFound(jobID)
        }
        let snapshot = job.transcript.read(from: offset)

        var lines: [String] = [statusLine(for: job)]
        if snapshot.outputWasDropped {
            lines.append("[output before the retained tail was dropped; showing what is still buffered]")
        }
        if snapshot.text.isEmpty {
            lines.append("[no new output since offset \(min(max(offset, 0), snapshot.nextOffset))]")
        } else {
            lines.append("[new output; poll again with offset \(snapshot.nextOffset) for later output]")
            lines.append(snapshot.text)
        }
        if job.status == .running {
            lines.append("Job is still running. Poll again with exec.job {\"action\":\"poll\",\"id\":\"\(jobID)\",\"offset\":\(snapshot.nextOffset)} or stop it with {\"action\":\"kill\",\"id\":\"\(jobID)\"}.")
        }
        return lines.joined(separator: "\n")
    }

    public func kill(jobID: String) async throws -> String {
        guard let job = jobsByID[jobID] else {
            throw DirectExecJobError.jobNotFound(jobID)
        }
        guard job.status == .running else {
            return "Job \(jobID) already finished: \(statusLine(for: job))"
        }
        job.killRequested = true
        let pid = job.process.processIdentifier
        job.process.terminate()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.forceKillIfStillRunning(jobID: jobID, pid: pid)
        }
        return "Requested termination of job \(jobID) (pid \(pid)). Final output remains readable with exec.job {\"action\":\"poll\",\"id\":\"\(jobID)\"}."
    }

    public func list() -> String {
        guard !jobOrder.isEmpty else {
            return "No background jobs. Start one with local.exec {\"command\":\"...\",\"background\":true}."
        }
        let lines = jobOrder.compactMap { jobID -> String? in
            guard let job = jobsByID[jobID] else {
                return nil
            }
            return "- \(statusLine(for: job)) — \(commandPreview(job.command))"
        }
        return """
        \(lines.count) background job(s):
        \(lines.joined(separator: "\n"))
        """
    }

    public func shutdown() {
        for job in jobsByID.values where job.status == .running {
            job.killRequested = true
            job.killReason = "session shutdown"
            job.process.terminate()
        }
    }

    // MARK: - Internal state transitions

    private func markFinished(jobID: String, exitCode: Int32) {
        guard let job = jobsByID[jobID], job.status == .running else {
            return
        }
        job.status = job.killRequested ? .killed : .exited
        job.exitCode = exitCode
        job.finishedAt = Date()
        job.process.terminationHandler = nil
        pruneFinishedJobs()
    }

    private func killIfRunning(jobID: String, reason: String) {
        guard let job = jobsByID[jobID], job.status == .running else {
            return
        }
        job.killRequested = true
        job.killReason = reason
        job.process.terminate()
    }

    private func forceKillIfStillRunning(jobID: String, pid: Int32) {
        guard let job = jobsByID[jobID], job.status == .running, pid > 0 else {
            return
        }
#if os(Linux)
        _ = Glibc.kill(pid, SIGKILL)
#else
        _ = Darwin.kill(pid, SIGKILL)
#endif
    }

    private func pruneFinishedJobs() {
        let finishedIDs = jobOrder.filter { jobsByID[$0]?.status != .running }
        guard finishedIDs.count > Self.maxRetainedFinishedJobs else {
            return
        }
        let removeCount = finishedIDs.count - Self.maxRetainedFinishedJobs
        for jobID in finishedIDs.prefix(removeCount) {
            jobsByID.removeValue(forKey: jobID)
            jobOrder.removeAll { $0 == jobID }
        }
    }

    // MARK: - Rendering helpers

    private func statusLine(for job: Job) -> String {
        switch job.status {
        case .running:
            return "job \(job.id): running (pid \(job.process.processIdentifier))"
        case .exited:
            return "job \(job.id): exited (code \(job.exitCode.map(String.init) ?? "unknown"))"
        case .killed:
            let reason = job.killReason.map { " — \($0)" } ?? ""
            return "job \(job.id): killed (code \(job.exitCode.map(String.init) ?? "unknown"))\(reason)"
        }
    }

    private func commandPreview(_ command: String) -> String {
        let singleLine = command
            .components(separatedBy: .newlines)
            .joined(separator: " ")
        guard singleLine.count > 80 else {
            return singleLine
        }
        return String(singleLine.prefix(80)) + "…"
    }

    private func requiredJobID(in arguments: [String: Any]) throws -> String {
        guard let jobID = arguments.string("id", "jobID", "job_id")?.nilIfBlank else {
            throw DirectToolError.missingArgument("id")
        }
        return jobID
    }
#else
    public init(maxRunningJobs: Int = DirectExecJobRuntime.defaultMaxRunningJobs) {
        _ = maxRunningJobs
    }

    public func startBackgroundJob(
        command: String,
        shellPath: String,
        workingDirectory: URL,
        environment: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) throws -> String {
        throw DirectExecJobError.unsupportedPlatform
    }

    public func execute(toolCall: DirectAgentToolCall) async throws -> String {
        throw DirectExecJobError.unsupportedPlatform
    }

    public func shutdown() {}
#endif
}
