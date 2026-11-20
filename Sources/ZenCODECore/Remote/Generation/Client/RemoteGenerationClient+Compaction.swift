//
//  RemoteGenerationClient+Compaction.swift
//  ZenCODE
//
//  Automatic context compaction of the HTTP (non-DS4) remote path: a preflight
//  before every request, sized with the prompt tokens the provider reported
//  for the previous one, and the single retry after a context-length
//  rejection. The policy is the shared deterministic one; no model is called.
//

import Foundation

extension RemoteGenerationClient {
    /// What a provider reported for one request set against the shared
    /// estimate of the session messages that request was built from.
    ///
    /// The shared estimator counts characters of role and content only: it
    /// misses the tool catalogue, the turn memory block and the per-message
    /// wire framing, so on its own it can stay under the compaction trigger
    /// while the provider already counts a full window. The ratio carries
    /// that difference onto the messages of the next request.
    struct ContextCalibration: Equatable, Sendable {
        let reportedPromptTokens: Int
        let estimatedTokens: Int

        /// Provider tokens expected for a history the shared estimator counts
        /// as `estimated`, or `nil` when the calibration cannot be applied.
        func projectedTokenCount(forEstimated estimated: Int) -> Int? {
            guard reportedPromptTokens > 0, estimatedTokens > 0, estimated > 0 else {
                return nil
            }
            let projected = Double(reportedPromptTokens) / Double(estimatedTokens)
                * Double(estimated)
            guard projected.isFinite, projected < Double(Int.max) else {
                return nil
            }
            return Int(projected)
        }
    }

    /// Budget for compacting `runtimeMessages`. `exactTokenCount` is the size
    /// of the prompt the provider would count for them (the DS4 engine
    /// tokenizer, or the calibrated projection of an HTTP provider); the
    /// budget converts between the shared estimator and real tokens with
    /// their ratio. `nil` keeps the estimator-only budget.
    func compactionBudget(
        for runtimeMessages: [AgentRuntimeMessage],
        exactTokenCount: Int?
    ) -> AgentConversationCompactionBudget {
        var inflationFactor = 1.0
        if let exactTokenCount, exactTokenCount > 0 {
            let estimated = AgentConversationCompactionSupport.estimatedTokenCount(
                for: runtimeMessages
            )
            if estimated > 0 {
                inflationFactor = Double(exactTokenCount) / Double(estimated)
            }
        }
        return AgentConversationCompactionBudget(
            contextWindowTokens: configuration.configuredContextWindowLimit,
            maxOutputTokens: configuration.maxOutputTokens,
            conversationInflationFactor: inflationFactor
        )
    }

    /// The calibrated size, in provider tokens, of `messages`; `nil` until the
    /// provider reported usage for this session.
    func calibratedTokenCount(
        forSessionID id: String,
        messages: [[String: Any]]
    ) -> Int? {
        guard let calibration = contextCalibrationBySessionID[id] else {
            return nil
        }
        let estimated = AgentConversationCompactionSupport.estimatedTokenCount(
            for: Self.agentRuntimeMessages(from: messages)
        )
        return calibration.projectedTokenCount(forEstimated: estimated)
    }

    /// Records the prompt size the provider reported for a request built from
    /// `messages` (the session array, not the outgoing copy that also carries
    /// the turn memory). Nothing is recorded without usage, for a session that
    /// was replaced meanwhile, or when no context window is configured.
    func recordContextCalibration(
        for lease: SessionLease,
        messages: [[String: Any]],
        usage: RemoteGenerationUsage?
    ) {
        guard ds4Generation == nil,
              configuration.configuredContextWindowLimit != nil,
              sessionGenerations[lease.id] == lease.generation,
              let reportedPromptTokens = usage?.promptTokens,
              reportedPromptTokens > 0 else {
            return
        }
        let estimatedTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: Self.agentRuntimeMessages(from: messages)
        )
        guard estimatedTokens > 0 else {
            return
        }
        contextCalibrationBySessionID[lease.id] = ContextCalibration(
            reportedPromptTokens: reportedPromptTokens,
            estimatedTokens: estimatedTokens
        )
    }

    /// Compacts the session when the next request would reach the policy
    /// trigger, counting the history by the last provider usage report.
    ///
    /// - Returns: the shared compaction result when the session was compacted
    ///   and the request must be built again from the compacted history.
    func compactSessionBeforeRequest(
        lease: SessionLease,
        attempts: inout Int
    ) throws -> AgentConversationCompactionResult? {
        guard configuration.configuredContextWindowLimit != nil,
              attempts < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts else {
            return nil
        }
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        guard let result = compactSessionMessages(
            id: lease.id,
            force: false,
            exactTokenCount: calibratedTokenCount(
                forSessionID: lease.id,
                messages: session.messages
            )
        ) else {
            return nil
        }
        attempts += 1
        return result
    }

    /// `true` when the provider refused the request for its context length.
    static func isContextLimitRejection(_ error: Error) -> Bool {
        guard case let .remoteFailure(message)? = error as? RemoteGenerationClientError else {
            return false
        }
        return SubscriptionCompactionSupport.messageIndicatesContextLimit(message)
    }

    /// Compacts after a context-limit rejection, aiming at a substantially
    /// smaller history than the one the provider refused.
    ///
    /// - Returns: the shared compaction result, or `nil` when the history
    ///   could not be reduced.
    func compactSessionForContextLimitRetry(
        lease: SessionLease
    ) throws -> AgentConversationCompactionResult? {
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let runtimeMessages = Self.agentRuntimeMessages(from: session.messages)
        let result = AgentConversationCompactionSupport.compactedMessagesForContextLimitRetry(
            runtimeMessages,
            budget: compactionBudget(
                for: runtimeMessages,
                exactTokenCount: calibratedTokenCount(
                    forSessionID: lease.id,
                    messages: session.messages
                )
            )
        )
        guard result.wasCompacted else {
            return nil
        }
        guard mutateSession(for: lease, { session in
            session.messages = Self.remoteMessages(
                compactionResult: result,
                preservingRecentFrom: session.messages
            )
        }) else {
            throw RemoteGenerationClientError.missingSession
        }
        contextCalibrationBySessionID[lease.id] = nil
        return result
    }
}
