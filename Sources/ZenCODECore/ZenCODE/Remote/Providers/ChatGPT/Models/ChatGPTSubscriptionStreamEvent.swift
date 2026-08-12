//
//  ChatGPTSubscriptionStreamEvent.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//

import Foundation

struct ChatGPTSubscriptionToolCallUpdate: Sendable {
    let id: String
    let title: String
    let status: String
    let rawInput: String?
    let output: String?
}

enum ChatGPTSubscriptionStreamEvent: Sendable {
    case thought(String)
    case content(String)
    case toolCall(ChatGPTSubscriptionToolCallUpdate)
    case modelLoaded(String)
    case contextWindow(DirectAgentContextWindowStatus)
    case completed(stopReason: String?)
}

/// Normalizes a stream event type string by trimming, replacing separators
/// with underscores, and lowercasing.
func normalizedEventType(_ type: String) -> String {
    type.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: ".", with: "_")
        .replacingOccurrences(of: "-", with: "_")
        .lowercased()
}
