//
//  ChatGPTSubscriptionGenerationClient+Payload.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension ChatGPTSubscriptionGenerationClient {
    static func sessionID(from object: [String: Any]) -> String? {
        let normalizedType = (object["type"] as? String)
            .map(normalizedEventType) ?? ""
        let directKeys = [
            "session_id",
            "sessionId",
            "thread_id",
            "threadId",
            "conversation_id",
            "conversationId"
        ]

        for key in directKeys {
            if let value = normalizedSessionID(object[key]) {
                return value
            }
        }

        if [
            "thread_started",
            "session_configured",
            "session_started",
            "conversation_started"
        ].contains(normalizedType),
           let value = normalizedSessionID(object["id"]) {
            return value
        }

        for key in ["session", "thread", "conversation"] {
            guard let nested = object[key] as? [String: Any] else {
                continue
            }
            for nestedKey in directKeys + ["id"] {
                if let value = normalizedSessionID(nested[nestedKey]) {
                    return value
                }
            }
        }

        return nil
    }

    static func normalizedSessionID(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
