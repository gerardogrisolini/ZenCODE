//
//  AgentRuntimeLauncher.swift
//  ZenCODE
//

import Foundation

/// Shared entry points for launching ZenCODE terminal and ACP runtimes.
public enum AgentRuntimeLauncher {
    /// Runs one non-interactive turn and writes only its final assistant text.
    @TerminalChatActor
    public static func runHeadless(
        configuration: AgentConfiguration,
        prompt: String,
        permissionAuthorizer: LocalExecPermissionAuthorizer,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async throws {
        try await ZenCODEHeadlessRunner.run(
            configuration: configuration,
            prompt: prompt,
            permissionAuthorizer: permissionAuthorizer,
            backendFactory: backendFactory
        )
    }

    /// Runs one terminal-chat lifecycle. The caller owns the supplied runner so
    /// it can preserve the task orchestrator while rebuilding the chat after
    /// `/setup`.
    @TerminalChatActor
    public static func runTerminalChat(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        runtimeSetupResumeSnapshot: TerminalChatResumeSnapshot? = nil
    ) async throws -> TerminalChatRunOutcome {
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner,
            permissionAuthorizer: permissionAuthorizer,
            runtimeSetupResumeSnapshot: runtimeSetupResumeSnapshot
        )
        return try await terminal.run()
    }

    /// Reads ACP requests from standard input and shuts down the bridge when input ends.
    public static func runACP(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async {
        let writer = ACPWriter()
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: backendFactory
        )
        let reader = StdioLineReader()
        let lines = acpLineStream(reader: reader)

        await withDiscardingTaskGroup { group in
            for await line in lines {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    continue
                }
                // A discarding group releases each child as soon as it finishes
                // instead of retaining a result per handled line, so a long ACP
                // session no longer grows an unbounded child list.
                //
                // addImmediateTask runs each child up to its first suspension
                // point before the next line is dequeued, preserving the order
                // in which ACP requests enter the bridge (e.g. a session/cancel
                // read after session/prompt reaches the actor in that order).
                group.addImmediateTask(name: "ZenCODE.ACP.handle-line") {
                    await bridge.handleLine(trimmedLine)
                }
            }

            // Input has ended (EOF or cancellation). Shut the bridge down while
            // still inside the task group so handlers suspended on a host
            // response (e.g. session/request_permission) are unblocked by
            // writer.failAllPending() before the group's implicit barrier waits
            // for its remaining children, which would otherwise hang.
            await bridge.shutdown()
        }
    }

    /// Produces ACP input lines without running the blocking stdin read on a
    /// Swift concurrency worker.
    ///
    /// The producer task itself only awaits ``readACPLineOffCooperativePool``.
    /// That bridge runs the `poll`/`read` transaction on its dedicated Dispatch
    /// queue and signals its token when this stream is terminated. Consequently,
    /// cancellation cannot leave a producer task parked on the cooperative pool
    /// or prevent the reader from finishing after EOF.
    static func acpLineStream(reader: StdioLineReader) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task(name: "ZenCODE.ACP.stdin-reader") {
                while let line = await readACPLineOffCooperativePool(reader: reader) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Performs one cancellation-aware stdin read on the Dispatch-backed
    /// blocking-read bridge shared with terminal input.
    ///
    /// This intentionally passes the bridge token into `StdioLineReader`: task
    /// cancellation is not visible from the dedicated Dispatch queue, so the
    /// poll loop must receive the token explicitly to release that thread.
    static func readACPLineOffCooperativePool(reader: StdioLineReader) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readLine(shouldCancel: token.isCancelled)
        }
    }
}
