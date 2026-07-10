//
//  ChatGPTSubscriptionGenerationClient+Payload.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    static func promptPayload(
        prompt: String,
        configuration: RequestConfiguration,
        attachments: [AgentRuntimeAttachment],
        includesHistory: Bool
    ) -> String {
        var sections: [String] = []
        let history = includesHistory ? renderedHistory(configuration.history) : ""
        if includesHistory,
           !history.isEmpty {
            sections.append(
                """
                Conversation so far:
                \(history)
                """
            )
        }

        let attachmentText = renderedAttachments(attachments)
        if !attachmentText.isEmpty {
            sections.append(
                """
                Attachments:
                \(attachmentText)
                """
            )
        }

        let requestSettings = renderedRequestSettings(configuration)
        if !requestSettings.isEmpty {
            sections.append(
                """
                Request settings:
                \(requestSettings)
                """
            )
        }

        sections.append(
            """
            Current request:
            \(prompt)
            """
        )
        return sections.joined(separator: "\n\n")
    }

    static func renderedRequestSettings(
        _ configuration: RequestConfiguration
    ) -> String {
        [
            renderedThinkingSetting(configuration.thinkingSelection),
            renderedDeveloperToolSetting()
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    static func renderedThinkingSetting(
        _ selection: AgentThinkingSelection?
    ) -> String {
        guard let selection else {
            return ""
        }

        switch selection {
        case .off:
            return "- Thinking: off. Answer directly and avoid extra deliberation."
        case .enabled:
            return "- Thinking: on."
        case .minimal:
            return "- Thinking effort: minimal."
        case .low:
            return "- Thinking effort: low."
        case .medium:
            return "- Thinking effort: medium."
        case .high:
            return "- Thinking effort: high."
        case .xhigh:
            return "- Thinking effort: xhigh."
        case .max:
            return "- Thinking effort: max."
        case .ultra:
            return "- Thinking effort: ultra."
        }
    }

    static func renderedDeveloperToolSetting() -> String {
        "- Xcode projects: `xcodebuild` is allowed. When building from the macOS app sandbox, keep build products inside the workspace, for example with `-derivedDataPath .zencode/DerivedData`. If Xcode reports that its license has not been accepted, stop and report that host setup issue."
    }

    static func renderedHistory(
        _ history: [AgentRuntimeMessage]
    ) -> String {
        history
            .suffix(12)
            .map { message in
                let role = message.role.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else {
                    return ""
                }
                return "\(role.capitalized): \(content)"
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    static func renderedAttachments(
        _ attachments: [AgentRuntimeAttachment]
    ) -> String {
        attachments.map { attachment in
            if let fileURL = attachment.fileURL {
                return "- \(attachment.originalFilename): \(fileURL.path)"
            }
            return "- \(attachment.originalFilename): embedded \(attachment.kind.rawValue)"
        }
        .joined(separator: "\n")
    }

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
#endif
