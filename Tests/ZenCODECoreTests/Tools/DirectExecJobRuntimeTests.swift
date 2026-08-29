//
//  DirectExecJobRuntimeTests.swift
//  ZenCODE
//

import Foundation
#if canImport(Glibc)
import Glibc
#endif
@testable import ZenCODECore
import Testing

/// Process exit is asynchronous by design. The tests wait for the runtime's
/// terminal status, not a guessed wall-clock delay; the suite limit remains the
/// guard against a genuine process-management regression.
@Suite(.timeLimit(.minutes(1)))
struct DirectExecJobRuntimeTests {
    @Test
    func catalogExposesExecJobAndBackgroundFlag() {
        let coreProcessNames = Set(DirectToolCatalog.coreProcessDescriptors.map(\.name))
        #expect(coreProcessNames.contains("local.exec"))
        #expect(coreProcessNames.contains("exec.job"))

        let baseNames = Set(DirectToolCatalog.baseDescriptors.map(\.name))
        #expect(baseNames.contains("exec.job"))

        let localExec = DirectToolCatalog.baseDescriptors.first { $0.name == "local.exec" }
        #expect(localExec?.inputSchema.contains("background") == true)
        #expect(localExec?.description.contains("background") == true)

        let execJob = DirectToolCatalog.baseDescriptors.first { $0.name == "exec.job" }
        #expect(execJob?.inputSchema.contains("\"poll\"") == true)
        #expect(execJob?.inputSchema.contains("\"kill\"") == true)
        #expect(execJob?.inputSchema.contains("\"list\"") == true)
    }

#if os(macOS) || os(Linux)
    @Test
    func backgroundJobRunsToCompletionAndReportsOutput() async throws {
        let runtime = DirectExecJobRuntime()
        let startOutput = try await runtime.startBackgroundJob(
            command: "printf zen-exec-job-output",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        #expect(startOutput.contains("Started background job job-1"))
        #expect(startOutput.contains("exec.job"))

        let finalPoll = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("exited")
        }
        #expect(finalPoll.contains("exited (code 0)"))
        #expect(finalPoll.contains("zen-exec-job-output"))
    }

    @Test
    func pollWithAdvancedOffsetReturnsOnlyNewOutput() async throws {
        let runtime = DirectExecJobRuntime()
        _ = try await runtime.startBackgroundJob(
            command: "printf abc",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        _ = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("exited")
        }

        let caughtUpPoll = try await runtime.poll(jobID: "job-1", offset: 3)
        #expect(caughtUpPoll.contains("no new output since offset 3"))
    }

    @Test
    func killTerminatesRunningJob() async throws {
        let runtime = DirectExecJobRuntime()
        _ = try await runtime.startBackgroundJob(
            command: "sleep 30",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let killOutput = try await runtime.kill(jobID: "job-1")
        #expect(killOutput.contains("Requested termination of job job-1"))

        let finalPoll = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("killed")
        }
        #expect(finalPoll.contains("job job-1: killed"))
    }

    /// An interrupt must reach the whole process tree. The child survives its
    /// parent shell via `exec sleep` and is only reaped if the runtime signals
    /// the isolated process group rather than the shell PID alone.
    @Test
    func interruptRunningJobsTerminatesJobAndReachesDescendants() async throws {
        let runtime = DirectExecJobRuntime()
        _ = try await runtime.startBackgroundJob(
            command: "sleep 30",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )

        let interruptedCount = await runtime.interruptRunningJobs()
        #expect(interruptedCount == 1)

        let finalPoll = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("killed")
        }
        #expect(finalPoll.contains("job job-1: killed"))
        #expect(finalPoll.contains("interrupted by user"))
        #expect(!finalPoll.contains("Job is still running"))
    }

    @Test
    func interruptRunningJobsSkipsFinishedJobs() async throws {
        let runtime = DirectExecJobRuntime()

        let idleCount = await runtime.interruptRunningJobs()
        #expect(idleCount == 0)

        _ = try await runtime.startBackgroundJob(
            command: "sleep 30",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let interruptedCount = await runtime.interruptRunningJobs()
        #expect(interruptedCount == 1)

        // Once the job reaches its terminal state a later interrupt no longer
        // sees it, so finished jobs are left untouched.
        _ = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("killed")
        }
        let afterExitCount = await runtime.interruptRunningJobs()
        #expect(afterExitCount == 0)
    }

    @Test
    func shutdownEscalatesAndWaitsForTermIgnoringJob() async throws {
        let runtime = DirectExecJobRuntime()
        _ = try await runtime.startBackgroundJob(
            command: "trap '' TERM; printf ready; while :; do sleep 1; done",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        _ = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("ready")
        }

        await runtime.shutdown()

        let finalPoll = try await runtime.poll(jobID: "job-1", offset: 0)
        #expect(finalPoll.contains("job job-1: killed"))
        #expect(!finalPoll.contains("Job is still running"))
    }

    @Test
    func unknownJobIdentifierThrowsJobNotFound() async throws {
        let runtime = DirectExecJobRuntime()
        await #expect(throws: DirectExecJobError.self) {
            _ = try await runtime.poll(jobID: "job-99", offset: 0)
        }
    }

    @Test
    func listRendersKnownJobs() async throws {
        let runtime = DirectExecJobRuntime()
        let emptyList = await runtime.list()
        #expect(emptyList.contains("No background jobs"))

        _ = try await runtime.startBackgroundJob(
            command: "printf listed",
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let list = await runtime.list()
        #expect(list.contains("job-1"))
        #expect(list.contains("printf listed"))
    }

    @Test
    func executorDispatchesBackgroundExecAndExecJob() async throws {
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let workingDirectory = FileManager.default.temporaryDirectory

        let startResult = await executor.execute(
            sessionID: "exec-job-tests",
            toolCall: DirectAgentToolCall(
                id: "call-1",
                name: "local.exec",
                argumentsObject: [
                    "command": "printf executor-background",
                    "background": true
                ],
                argumentsJSON: #"{"command":"printf executor-background","background":true}"#
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: ["local.exec", "exec.job"]
        )
        #expect(startResult.status == .completed)
        #expect(startResult.output.contains("Started background job job-1"))

        let pollOutput = await pollExecutorUntil(
            executor: executor,
            sessionID: "exec-job-tests",
            workingDirectory: workingDirectory
        ) {
            $0.contains("exited (code 0)") && $0.contains("executor-background")
        }
        #expect(
            pollOutput.contains("exited (code 0)"),
            "Background job did not report its exit. Last poll:\n\(pollOutput)"
        )
        #expect(
            pollOutput.contains("executor-background"),
            "Background job transcript was incomplete. Last poll:\n\(pollOutput)"
        )

        let listResult = await executor.execute(
            sessionID: "exec-job-tests",
            toolCall: DirectAgentToolCall(
                id: "call-3",
                name: "exec.job",
                argumentsObject: ["action": "list"],
                argumentsJSON: #"{"action":"list"}"#
            ),
            workingDirectory: workingDirectory,
            allowedToolNames: ["local.exec", "exec.job"]
        )
        #expect(listResult.output.contains("job-1"))
    }

    @Test
    func execJobIsRejectedWhenNotAllowed() async throws {        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let result = await executor.execute(
            sessionID: "exec-job-tests",
            toolCall: DirectAgentToolCall(
                id: "call-1",
                name: "exec.job",
                argumentsObject: ["action": "list"],
                argumentsJSON: #"{"action":"list"}"#
            ),
            workingDirectory: FileManager.default.temporaryDirectory,
            allowedToolNames: ["local.readFile"]
        )
        #expect(result.status != .completed)
    }

    /// The full ESC path: the session runner's interrupt flows through the
    /// backend's `DirectToolExecutor` into the job runtime, so a running job
    /// ends up `.killed` with its transcript still pollable.
    @Test
    func executorInterruptBackgroundJobsTerminatesRunningJob() async throws {
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        _ = await executor.execute(
            sessionID: "exec-job-tests",
            toolCall: DirectAgentToolCall(
                id: "call-interrupt",
                name: "local.exec",
                argumentsObject: [
                    "command": "sleep 30",
                    "background": true
                ],
                argumentsJSON: #"{"command":"sleep 30","background":true}"#
            ),
            workingDirectory: FileManager.default.temporaryDirectory,
            allowedToolNames: ["local.exec", "exec.job"]
        )

        let interruptedCount = await executor.interruptBackgroundJobs()
        #expect(interruptedCount == 1)

        let finalPoll = try await pollUntil(runtime: executor.execJobRuntime, jobID: "job-1") {
            $0.contains("killed")
        }
        #expect(finalPoll.contains("job job-1: killed"))
    }

    private func pollUntil(
        runtime: DirectExecJobRuntime,
        jobID: String,
        condition: (String) -> Bool
    ) async throws -> String {
        var output = try await runtime.poll(jobID: jobID, offset: 0)
        while !condition(output) {
            await Task.yield()
            output = try await runtime.poll(jobID: jobID, offset: 0)
        }
        return output
    }

    /// The executor owns the job runtime, so exercising the tool dispatch needs
    /// to perform the real `exec.job` call each round. Yielding lets the process
    /// exit monitor publish its status without making test correctness depend on
    /// a fixed sleep interval.
    private func pollExecutorUntil(
        executor: DirectToolExecutor,
        sessionID: String,
        workingDirectory: URL,
        condition: (String) -> Bool
    ) async -> String {
        while true {
            let pollResult = await executor.execute(
                sessionID: sessionID,
                toolCall: DirectAgentToolCall(
                    id: UUID().uuidString,
                    name: "exec.job",
                    argumentsObject: ["action": "poll", "id": "job-1"],
                    argumentsJSON: #"{"action":"poll","id":"job-1"}"#
                ),
                workingDirectory: workingDirectory,
                allowedToolNames: ["local.exec", "exec.job"]
            )
            if condition(pollResult.output) {
                return pollResult.output
            }
            await Task.yield()
        }
    }
#endif

#if os(Linux)
    /// Regression test: killing a background job must terminate the whole
    /// process tree, not just the outer shell. A descendant that survives the
    /// shell's SIGTERM gets reparented to init and keeps running as an orphan.
    /// The runtime uses the isolated process group created by Foundation on
    /// Linux so `kill(-pgid)` reaches every descendant (pipes, subshells,
    /// long-running servers).
    @Test
    func killReachesChildProcessesNotJustTheShell() async throws {
        let runtime = DirectExecJobRuntime()
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("exec-job-child-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        // The inner subshell records its own PID (kept via `exec`) then sleeps
        // forever. Without a process-group kill, terminating the outer job shell
        // would orphan this child and it would keep running under init.
        let command = "sh -c 'echo $$ > \"\(markerURL.path)\"; exec sleep 1000'"
        _ = try await runtime.startBackgroundJob(
            command: command,
            shellPath: "/bin/sh",
            workingDirectory: FileManager.default.temporaryDirectory
        )

        // Wait for the child PID to land in the marker file. The marker itself
        // is the process-start handshake, so there is no scheduling budget to
        // tune under parallel CI load.
        let childPID = await waitForLinuxChildPID(at: markerURL)
        #expect(childPID > 0)

        _ = try await runtime.kill(jobID: "job-1")
        _ = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("killed")
        }

        // `kill(pid, 0)` still succeeds for exited-but-unreaped zombies in
        // minimal containers, so inspect `/proc` until the child is no longer
        // executable. The suite time limit bounds an actual runtime regression.
        while linuxProcessIsRunning(childPID) {
            await Task.yield()
        }
        #expect(
            !linuxProcessIsRunning(childPID),
            "child process remained running after the job kill"
        )
    }

    /// Returns false once a process is absent or can no longer execute. Linux
    /// keeps an exited-but-unreaped process in `/proc` as a zombie, and
    /// `kill(pid, 0)` reports that PID as existing until its parent reaps it.
    private func linuxProcessIsRunning(_ processID: Int32) -> Bool {
        guard Glibc.kill(processID, 0) == 0 else {
            return false
        }

        let statusURL = URL(fileURLWithPath: "/proc/\(processID)/status")
        guard let status = try? String(contentsOf: statusURL, encoding: .utf8),
              let stateLine = status.split(separator: "\n").first(where: {
                  $0.hasPrefix("State:")
              }) else {
            // `/proc` may be unavailable or restricted. Retain the portable
            // existence check rather than incorrectly declaring a live child dead.
            return Glibc.kill(processID, 0) == 0
        }

        let fields = stateLine.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2 else {
            return true
        }
        return fields[1] != "Z" && fields[1] != "X" && fields[1] != "x"
    }

    private func waitForLinuxChildPID(at markerURL: URL) async -> Int32 {
        while true {
            if let text = try? String(contentsOf: markerURL, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            await Task.yield()
        }
    }
#endif
}
