import Foundation

/// Executes an already-committed assistant tool batch on its session owner's actor.
/// The synchronous persistence closure must validate the lease and commit every
/// supplied result without suspension. Provider-specific wire state stays local
/// to the owner; callbacks never observe a partially closed cancelled batch.
enum RemoteToolBatchExecutor {
    static func run(
        _ toolCalls: [DirectAgentToolCall],
        isolation: isolated (any Actor),
        validateLease: () throws -> Void,
        execute: (DirectAgentToolCall) async throws -> DirectAgentToolResult,
        persist: ([(DirectAgentToolCall, DirectAgentToolResult)]) throws -> Void,
        onEvent: @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        var completedCount = 0
        do {
            for toolCall in toolCalls {
                try Task.checkCancellation()
                try validateLease()
                await onEvent(.toolCallStarted(toolCall))
                try Task.checkCancellation()
                try validateLease()
                let result = try await execute(toolCall)
                // An executor may return a real result despite cancellation.
                // Save it before observing cancellation or invoking user code.
                try validateLease()
                try persist([(toolCall, result)])
                completedCount += 1
                await onEvent(.toolCallCompleted(toolCall, result))
            }
            // Also covers empty batches and the final allowed generation round.
            try Task.checkCancellation()
            try validateLease()
        } catch is CancellationError {
            try validateLease()
            let cancellation = DirectAgentToolResult(
                output: "Tool execution cancelled before dispatch.",
                summary: "Tool execution cancelled before dispatch.",
                status: DirectToolExecutor.toolResultStatus(for: CancellationError())
            )
            let pending = toolCalls.dropFirst(completedCount)
            if !pending.isEmpty {
                try persist(pending.map { ($0, cancellation) })
            }
            // Do not check cancellation while draining: every committed pending
            // call needs a result, but a callback may replace the entire session.
            for toolCall in pending {
                try validateLease()
                await onEvent(.toolCallCompleted(toolCall, cancellation))
            }
            try validateLease()
            throw CancellationError()
        }
    }
}
