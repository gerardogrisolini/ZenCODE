//
//  AgentToolRoundPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

public enum AgentToolRoundPolicy {
    public static let minimumMaxToolRounds = 1
    public static let defaultMaxToolRounds = 1000

    public static func isValidMaxToolRounds(_ value: Int) -> Bool {
        value >= minimumMaxToolRounds
    }

    public static func normalizedMaxToolRounds(_ value: Int) -> Int {
        max(minimumMaxToolRounds, value)
    }

    /// Whether `error` reports the tool-round limit: the model asked for tools
    /// for ``maxToolRounds`` rounds without finishing, so the turn ended the
    /// way a turn that reaches a provider stop reason ends, not by failing.
    /// Every generation client that enforces the limit reports it through one
    /// of these errors; a channel can answer the turn as a stop reason
    /// instead of an error response.
    public static func isToolRoundLimit(_ error: Error) -> Bool {
        if case .tooManyToolRounds = error as? RemoteGenerationClientError {
            return true
        }
        if case .tooManyToolRounds = error as? ChatGPTSubscriptionGenerationError {
            return true
        }
        return false
    }
}
