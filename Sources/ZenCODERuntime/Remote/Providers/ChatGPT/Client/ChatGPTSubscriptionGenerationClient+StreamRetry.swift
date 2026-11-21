//
//  ChatGPTSubscriptionGenerationClient+StreamRetry.swift
//  ZenCODE
//
//  Retry support of the ChatGPT Subscription prompt loop: classification of
//  stream interruptions, authentication failures and lost continuations, and
//  the diagnostics reported when a turn is retried.
//

import Foundation
import ToolCore
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    static func continuationReplayFallbackDiagnostic() -> String {
        "ChatGPT Subscription lost the previous response id (the WebSocket "
            + "continuation is no longer available); retrying this turn with a "
            + "full conversation replay."
    }

    static let maxStreamInterruptionRetries = 1

    static func streamInterruptionRetryDiagnostic() -> String {
        "ChatGPT Subscription response was interrupted by a transient transport "
            + "failure; reopening the connection and retrying this turn with "
            + "a full conversation replay."
    }

    static func httpFallbackDiagnostic() -> String {
        "ChatGPT Subscription switched this session from WebSocket to HTTP "
            + "streaming after a recoverable WebSocket backend failure."
    }

    static func shouldRetryStreamInterruption(
        _ error: Error,
        completedRetries: Int
    ) -> Bool {
        guard completedRetries >= 0,
              completedRetries < maxStreamInterruptionRetries else {
            return false
        }
        return isRetryableStreamInterruption(error)
    }

    static func underlyingStreamInterruptionError(_ error: Error) -> Error {
        if let failure = error as?
            ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure {
            return failure.underlying
        }
        return error
    }

    static func isRetryableStreamInterruption(_ error: Error) -> Bool {
        let error = underlyingStreamInterruptionError(error)
        guard !ChatGPTSubscriptionResponsesClient.isCancellationError(error) else {
            return false
        }
        if let error = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = error,
           status == 429 {
            // The Responses client already applied its bounded backoff budget.
            // A second full-turn retry would only duplicate the same rate-limit
            // batch and delay the enriched limit error shown to the user.
            return false
        }
        return ChatGPTSubscriptionResponsesClient.isRetryableTransportError(error)
            || isAuthenticationFailure(error)
    }

    /// True when either transport returns an auth-related HTTP status (401/403).
    /// Such failures warrant a forced token refresh.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let error = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = error {
            return status == 401 || status == 403
        }
        if let error = error as? ChatGPTSubscriptionGenerationError,
           case let .http(status, _) = error {
            return status == 401 || status == 403
        }
        return false
    }

    static func authRefreshDiagnostic() -> String {
        "ChatGPT Subscription returned an authentication error; refreshed "
            + "the access token and will retry."
    }

    static func continuationUnavailableError(
        from error: Error
    ) -> ChatGPTSubscriptionGenerationError? {
        if let error = error as? ChatGPTSubscriptionGenerationError {
            switch error {
            case .continuationUnavailable:
                return error
            case let .http(_, output), let .responseFailed(output):
                guard messageIndicatesContinuationUnavailable(output) else {
                    return nil
                }
                return .continuationUnavailable(output)
            default:
                return nil
            }
        }

        let message = error.localizedDescription
        guard messageIndicatesContinuationUnavailable(message) else {
            return nil
        }
        return .continuationUnavailable(message)
    }

    static func messageIndicatesContinuationUnavailable(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("previous_response_id")
                || normalized.contains("previous response")
                || normalized.contains("response id")
                || normalized.contains("response_id")
                || normalized.contains("response with id") else {
            return false
        }

        if normalized.contains("unsupported parameter")
            && normalized.contains("previous_response_id") {
            return true
        }

        return normalized.contains("not found")
            || normalized.contains("cannot be found")
            || normalized.contains("could not be found")
            || normalized.contains("not available")
            || normalized.contains("unavailable")
            || normalized.contains("cannot resolve")
            || normalized.contains("could not resolve")
            || normalized.contains("does not exist")
            || normalized.contains("expired")
            || normalized.contains("invalid")
            || normalized.contains("missing")
    }
}
