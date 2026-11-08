//
//  AgentRuntimeLauncher.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Shared entry points for launching ZenCODE terminal, Telegram, and ACP runtimes.
public enum AgentRuntimeLauncher {
    /// Runs one non-interactive turn. Legacy headless mode writes only the final
    /// assistant text; JSONL mode writes the approved lifecycle records. The
    /// sinks receive that output instead of standard output (nil prints it).
    @ChatSessionActor
    public static func runHeadless(
        configuration: AgentConfiguration,
        prompt: String,
        permissionAuthorizer: LocalExecPermissionAuthorizer,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        jsonlSink: ZenCODEHeadlessJSONLWriter.Sink? = nil,
        textSink: ZenCODEHeadlessRunner.TextSink? = nil
    ) async throws {
        try await ZenCODEHeadlessRunner.run(
            configuration: configuration,
            prompt: prompt,
            permissionAuthorizer: permissionAuthorizer,
            backendFactory: backendFactory,
            jsonlSink: jsonlSink,
            textSink: textSink
        )
    }

    /// Runs one terminal-chat lifecycle. The caller owns the supplied runner,
    /// or the host whose runner it is. With `sessionHost` the terminal opens
    /// its slot there and the caller shuts the host down
    /// (``ChatSessionHost/shutdown(keepingExternalTools:)``); `sessionRunner`
    /// is then ignored, as the host's runner is the terminal's. Without a host
    /// the terminal builds one over `sessionRunner`, or over a new runner.
    @ChatSessionActor
    public static func runTerminalChat(
        configuration: AgentConfiguration,
        stdinIsTerminal: Bool,
        sessionRunner: AgentCoreSessionRunner? = nil,
        sessionHost: ChatSessionHost? = nil,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil
    ) async throws {
        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: stdinIsTerminal,
            sessionRunner: sessionRunner,
            sessionHost: sessionHost,
            permissionAuthorizer: permissionAuthorizer,
            telegramTransportFactory: nil
        )
        try await terminal.run()
    }

    /// Runs the session of `zen --telegram` in this process: no TUI, the slot
    /// driven only by the linked Telegram chat, a timestamped log on the
    /// preserved standard error, and nothing on standard output, until
    /// SIGTERM or SIGINT stops it (see `ZenCODETelegramRunner`). Returns the
    /// exit status: 0 after a stop, 1 when the startup or the link to
    /// Telegram failed, which the log tells.
    public static func runTelegram(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory? = nil
    ) async -> Int32 {
        await ZenCODETelegramRunner.runProcess(
            configuration: configuration,
            backendFactory: backendFactory
        )
    }

    /// Reads ACP requests from standard input and shuts down the bridge when input ends.
    public static func runACP(
        configuration: AgentConfiguration,
        backendFactory: AgentRuntimeBackendFactory? = nil,
        setupRequired: Bool = false
    ) async {
        let writer = ACPWriter()
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: writer,
            backendFactory: backendFactory,
            setupRequired: setupRequired
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
