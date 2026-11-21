//
//  RemoteToolBatchDispatcher.swift
//  ZenCODE
//
//  Dispatches a committed assistant tool-call batch for every remote
//  generation client and closes it on cancellation.
//

import Foundation

/// The session values one tool dispatch needs, read through the caller's
/// session lease immediately before the call.
struct RemoteToolDispatchSession {
    let sessionID: String
    let workingDirectory: URL
    let allowedToolNames: Set<String>?
}

/// Shared tool loop of `RemoteGenerationClient`,
/// `ChatGPTSubscriptionGenerationClient` and
/// `AnthropicSubscriptionGenerationClient`.
///
/// Provider-specific parts are supplied by the caller: how the leased session
/// is read, how result messages are appended to it, and which error reports a
/// session that was closed or replaced in the meantime. The dispatcher runs on
/// the caller's actor (`isolation`), so its closures read and mutate the
/// session synchronously and the only suspensions are the event callbacks and
/// the tool executions themselves.
enum RemoteToolBatchDispatcher {
    static let cancelledBeforeDispatchMessage = "Tool execution cancelled before dispatch."

    /// Executes `toolCalls` and appends one result message per call, in the
    /// order of the calls.
    ///
    /// The calls run in order, one after the other, except that consecutive
    /// calls to core tools that only read
    /// (`DirectToolCatalog.coreReadOnlyToolNames`) run together as one group:
    /// none of them changes what another returns, so the batch waits for the
    /// slowest of them instead of for their sum. The events of a group are
    /// still reported call by call, each start followed by its completion,
    /// and its results are appended together before the first completion.
    ///
    /// Cancellation is observed before the first `toolCallStarted` event of
    /// each group, before its execution, and once more after the batch, which
    /// also covers a cancellation by the final completion callback. On
    /// cancellation every call that has not produced a result is closed with
    /// `cancelledBeforeDispatchMessage` in a single append, its completion is
    /// reported, and `CancellationError` is rethrown, so the transcript never
    /// holds an unanswered tool call and a later prompt can resume.
    ///
    /// - Parameters:
    ///   - currentSession: The leased session, or `nil` once it is gone.
    ///   - appendToolResults: Appends the messages to the leased session in
    ///     one mutation; returns `false` once the session is gone.
    ///   - missingSessionError: Thrown when the leased session is gone.
    static func dispatch(
        _ toolCalls: [DirectAgentToolCall],
        toolExecutor: DirectToolExecutor,
        currentSession: () -> RemoteToolDispatchSession?,
        appendToolResults: ([[String: Any]]) -> Bool,
        missingSessionError: any Error,
        onEvent: @Sendable (DirectAgentEvent) async -> Void,
        isolation: isolated (any Actor)? = #isolation
    ) async throws {
        var completedToolCount = 0
        do {
            for group in dispatchGroups(of: toolCalls) {
                try Task.checkCancellation()
                guard currentSession() != nil else {
                    throw missingSessionError
                }
                await onEvent(.toolCallStarted(group[0]))
                try Task.checkCancellation()
                guard let activeSession = currentSession() else {
                    throw missingSessionError
                }
                let results: [DirectAgentToolResult]
                if group.count == 1 {
                    results = [await toolExecutor.execute(
                        sessionID: activeSession.sessionID,
                        toolCall: group[0],
                        workingDirectory: activeSession.workingDirectory,
                        allowedToolNames: activeSession.allowedToolNames
                    )]
                } else {
                    results = await concurrentResults(
                        of: group,
                        toolExecutor: toolExecutor,
                        session: activeSession
                    )
                }
                // Persist the obtained results before a reentrant callback can
                // cancel the turn. Never replace an executed tool's result.
                guard appendToolResults(zip(group, results).map { toolCall, result in
                    RemoteGenerationClient.toolResultMessage(toolCall: toolCall, result: result)
                }) else {
                    throw missingSessionError
                }
                completedToolCount += group.count
                await onEvent(.toolCallCompleted(group[0], results[0]))
                // The other calls of a group have already run and their
                // results are in the session: each one reports its start and
                // its completion, with no cancellation check in between.
                for (toolCall, result) in zip(group, results).dropFirst() {
                    await onEvent(.toolCallStarted(toolCall))
                    await onEvent(.toolCallCompleted(toolCall, result))
                }
            }
            // Includes cancellation by the final completion callback, even
            // when this is the last permitted tool round.
            try Task.checkCancellation()
            guard currentSession() != nil else {
                throw missingSessionError
            }
        } catch is CancellationError {
            let pending = toolCalls.dropFirst(completedToolCount)
            let cancellation = DirectAgentToolResult(
                output: cancelledBeforeDispatchMessage,
                summary: cancelledBeforeDispatchMessage,
                status: DirectToolExecutor.toolResultStatus(for: CancellationError())
            )
            // Close the entire committed batch without suspension. Completion
            // callbacks may reset the session, so none may run before all
            // pending results are appended to the still-valid lease.
            guard appendToolResults(pending.map { toolCall in
                RemoteGenerationClient.toolResultMessage(toolCall: toolCall, result: cancellation)
            }) else {
                throw missingSessionError
            }
            for toolCall in pending {
                guard currentSession() != nil else {
                    throw missingSessionError
                }
                await onEvent(.toolCallCompleted(toolCall, cancellation))
            }
            throw CancellationError()
        }
    }

    /// The groups a batch is dispatched in, one after the other: each run of
    /// consecutive calls to core tools that only read is one group, and every
    /// other call is a group of its own. No group is empty.
    static func dispatchGroups(of toolCalls: [DirectAgentToolCall]) -> [[DirectAgentToolCall]] {
        var groups: [[DirectAgentToolCall]] = []
        for toolCall in toolCalls {
            if readsOnly(toolCall), let previous = groups.last?.last, readsOnly(previous) {
                groups[groups.count - 1].append(toolCall)
            } else {
                groups.append([toolCall])
            }
        }
        return groups
    }

    private static func readsOnly(_ toolCall: DirectAgentToolCall) -> Bool {
        DirectToolCatalog.coreReadOnlyToolNames.contains(toolCall.name)
    }

    /// The results of the calls of `group`, in their order, all running at
    /// once. Every call is waited for, also when the turn is cancelled
    /// meanwhile: the executor returns a result for a cancelled call too.
    private static func concurrentResults(
        of group: [DirectAgentToolCall],
        toolExecutor: DirectToolExecutor,
        session: RemoteToolDispatchSession
    ) async -> [DirectAgentToolResult] {
        await withTaskGroup(of: (Int, DirectAgentToolResult).self) { tasks in
            for (index, toolCall) in group.enumerated() {
                tasks.addTask {
                    (index, await toolExecutor.execute(
                        sessionID: session.sessionID,
                        toolCall: toolCall,
                        workingDirectory: session.workingDirectory,
                        allowedToolNames: session.allowedToolNames
                    ))
                }
            }
            var results = [DirectAgentToolResult?](repeating: nil, count: group.count)
            for await (index, result) in tasks {
                results[index] = result
            }
            return results.compactMap(\.self)
        }
    }
}
