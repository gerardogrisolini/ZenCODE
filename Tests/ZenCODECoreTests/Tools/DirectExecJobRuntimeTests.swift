//
//  DirectExecJobRuntimeTests.swift
//  ZenCODE
//

import Foundation
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

        let deadline = Date().addingTimeInterval(10)
        var pollOutput = ""
        while Date() < deadline {
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
            if pollOutput.contains("exited") {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(pollOutput.contains("exited (code 0)"))
        #expect(pollOutput.contains("executor-background"))

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
}
