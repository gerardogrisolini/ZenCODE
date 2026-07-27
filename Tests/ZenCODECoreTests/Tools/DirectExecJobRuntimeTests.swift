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

@Suite
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

        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var pollOutput = ""
        repeat {
            let pollResult = await executor.execute(
                sessionID: "exec-job-tests",
                toolCall: DirectAgentToolCall(
                    id: "call-2",
                    name: "exec.job",
                    argumentsObject: ["action": "poll", "id": "job-1"],
                    argumentsJSON: #"{"action":"poll","id":"job-1"}"#
                ),
                workingDirectory: workingDirectory,
                allowedToolNames: ["local.exec", "exec.job"]
            )
            pollOutput = pollResult.output
            if pollOutput.contains("exited (code 0)"),
               pollOutput.contains("executor-background") {
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        #expect(
            pollOutput.contains("exited (code 0)"),
            "Background job did not exit within 30 seconds. Last poll:\n\(pollOutput)"
        )
        #expect(
            pollOutput.contains("executor-background"),
            "Background job transcript was incomplete after 30 seconds. Last poll:\n\(pollOutput)"
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
    func execJobIsRejectedWhenNotAllowed() async throws {
        let executor = DirectToolExecutor(
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

    private func pollUntil(
        runtime: DirectExecJobRuntime,
        jobID: String,
        timeout: TimeInterval = 10,
        condition: (String) -> Bool
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var output = try await runtime.poll(jobID: jobID, offset: 0)
        while !condition(output), Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
            output = try await runtime.poll(jobID: jobID, offset: 0)
        }
        return output
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

        // Wait for the child PID to land in the marker file.
        let startDeadline = Date().addingTimeInterval(5)
        var childPID: Int32 = 0
        while Date() < startDeadline {
            if let text = try? String(contentsOf: markerURL, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(childPID > 0)

        _ = try await runtime.kill(jobID: "job-1")
        _ = try await pollUntil(runtime: runtime, jobID: "job-1") {
            $0.contains("killed")
        }

        // Allow time for the SIGTERM → 2s grace → SIGKILL escalation to stop the
        // whole group. Minimal CI containers do not always run an init process
        // that promptly reaps orphaned zombies; `kill(pid, 0)` still succeeds for
        // those already-dead processes, so inspect the Linux process state too.
        let reapDeadline = Date().addingTimeInterval(6)
        while Date() < reapDeadline {
            if !linuxProcessIsRunning(childPID) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
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
#endif
}
