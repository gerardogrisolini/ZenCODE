//
//  ChatGPTSubscriptionGenerationClient+StreamFailureDecision.swift
//  ZenCODE
//
//  Pure classification of a failed ChatGPT Subscription stream request.
//

/// What the prompt loop does after one ChatGPT Subscription request failed.
///
/// The decision only classifies the failure. Refreshing credentials, resetting
/// the continuation and transport, compacting for the retry and reporting the
/// diagnostics remain with the prompt loop, which applies them in order.
enum ChatGPTStreamFailureDecision: Equatable, Sendable {
    /// Surface the request error unchanged.
    case rethrow
    /// The server lost the `previous_response_id` state: drop the continuation
    /// and replay the whole conversation.
    case replayWithoutContinuation
    /// A transient transport interruption within the per-request budget: retry
    /// on a fresh connection, after a forced token refresh when
    /// `refreshCredentials` is true.
    case retryInterruption(refreshCredentials: Bool)
    /// The first context-limit refusal of the turn: compact the history and
    /// retry once.
    case retryAfterContextLimit
}

extension ChatGPTSubscriptionGenerationClient {
    /// Classifies a failed stream request.
    ///
    /// The cascade order is part of the contract: cancellation first, then a
    /// replay-unsafe failure that is not a retryable interruption, then the
    /// continuation replay fallback, then the interruption retry, and finally
    /// the single context-limit retry.
    static func streamFailureDecision(
        for error: Error,
        isCancelled: Bool,
        hasContinuationReplay: Bool,
        streamInterruptionRetries: Int,
        didRetryAfterContextLimit: Bool
    ) -> ChatGPTStreamFailureDecision {
        if isCancelled || ChatGPTSubscriptionResponsesClient.isCancellationError(error) {
            return .rethrow
        }
        let shouldRetryStreamInterruption = shouldRetryStreamInterruption(
            error,
            completedRetries: streamInterruptionRetries
        )
        if error is ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure,
           !shouldRetryStreamInterruption {
            // A callback error or a non-transport stream failure may have
            // crossed a side-effecting boundary and must not be replayed. A
            // transient transport interruption is retried below by discarding
            // the attempt's accumulator and reopening the turn on a fresh
            // connection.
            return .rethrow
        }
        if hasContinuationReplay, continuationUnavailableError(from: error) != nil {
            return .replayWithoutContinuation
        }
        if shouldRetryStreamInterruption {
            // A 401/403 from either transport means the access token is stale
            // on the server even though the local expiry window passed.
            return .retryInterruption(
                refreshCredentials: isAuthenticationFailure(
                    underlyingStreamInterruptionError(error)
                )
            )
        }
        guard isContextLimitError(error), !didRetryAfterContextLimit else {
            return .rethrow
        }
        return .retryAfterContextLimit
    }
}
