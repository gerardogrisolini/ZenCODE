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

    /// Executes `toolCalls` in order and appends one result message per call.
    ///
    /// Cancellation is observed before each `toolCallStarted` event, before
    /// each execution, and once more after the batch, which also covers a
    /// cancellation by the final completion callback. On cancellation every
    /// call that has not produced a result is closed with
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
            for toolCall in toolCalls {
                try Task.checkCancellation()
                guard currentSession() != nil else {
                    throw missingSessionError
                }
                await onEvent(.toolCallStarted(toolCall))
                try Task.checkCancellation()
                guard let activeSession = currentSession() else {
                    throw missingSessionError
                }
                let result = await toolExecutor.execute(
                    sessionID: activeSession.sessionID,
                    toolCall: toolCall,
                    workingDirectory: activeSession.workingDirectory,
                    allowedToolNames: activeSession.allowedToolNames
                )
                // Persist an obtained result before a reentrant callback can
                // cancel the turn. Never replace an executed tool's result.
                guard appendToolResults([
                    RemoteGenerationClient.toolResultMessage(toolCall: toolCall, result: result)
                ]) else {
                    throw missingSessionError
                }
                completedToolCount += 1
                await onEvent(.toolCallCompleted(toolCall, result))
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
}
