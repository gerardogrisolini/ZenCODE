//
//  ChatGPTSubscriptionGenerationError.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//
#if os(macOS)
import Foundation

enum ChatGPTSubscriptionGenerationError: LocalizedError {
    case missingSession
    case cancelled
    case invalidResponse
    case http(status: Int, output: String)
    case responseFailed(String)
    case tooManyToolRounds(Int)

    var errorDescription: String? {
        switch self {
        case .missingSession:
            return "The ChatGPT Subscription agent session is missing."
        case .cancelled:
            return "The ChatGPT Subscription request was cancelled."
        case .invalidResponse:
            return "ChatGPT Subscription returned an invalid response."
        case let .http(status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "ChatGPT Subscription request failed with HTTP \(status)."
            }
            return "ChatGPT Subscription request failed with HTTP \(status): \(detail)"
        case let .responseFailed(message):
            return message
        case let .tooManyToolRounds(limit):
            return "The ChatGPT Subscription model requested tools for \(limit) rounds without finishing."
        }
    }
}
#endif
