//
//  AgentConversationCompactionSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation

public enum AgentConversationCompactionPolicy {
    public static let triggerFraction = 0.95
    public static let targetFraction = 0.25
    public static let defaultRecentMessageCount = 12
    public static let minimumRecentMessageCount = 4
    public static let maximumSummaryCharacters = 4_000
    public static let minimumSummaryCharacters = 800

    public static func triggerTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * triggerFraction)
    }

    public static func targetTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * targetFraction)
    }

    public static func shouldCompactHistory(
        usedTokens: Int,
        maxTokens: Int,
        messageCount: Int,
        force: Bool = false
    ) -> Bool {
        guard maxTokens > 0 else {
            return false
        }

        return force
            || (
                messageCount > minimumRecentMessageCount
                    && usedTokens > triggerTokenCount(for: maxTokens)
            )
    }
}

public struct AgentConversationCompactionResult: Sendable {
    public let messages: [AgentRuntimeMessage]
    public let wasCompacted: Bool
    public let originalEstimatedTokenCount: Int
    public let estimatedTokenCount: Int
    public let maxTokens: Int?
    public let compactedSystemPrompt: String?
    public let keptRecentMessageCount: Int

    public init(
        messages: [AgentRuntimeMessage],
        wasCompacted: Bool,
        originalEstimatedTokenCount: Int,
        estimatedTokenCount: Int,
        maxTokens: Int?,
        compactedSystemPrompt: String?,
        keptRecentMessageCount: Int
    ) {
        self.messages = messages
        self.wasCompacted = wasCompacted
        self.originalEstimatedTokenCount = originalEstimatedTokenCount
        self.estimatedTokenCount = estimatedTokenCount
        self.maxTokens = maxTokens
        self.compactedSystemPrompt = compactedSystemPrompt
        self.keptRecentMessageCount = keptRecentMessageCount
    }
}

public enum AgentConversationCompactionSupport {
    public static let memorySummaryHeader = "Conversation memory summary from earlier turns."

    public static func compactedMessagesIfNeeded(
        _ messages: [AgentRuntimeMessage],
        maxTokens: Int?,
        force: Bool = false
    ) -> AgentConversationCompactionResult {
        let rawTokenCount = estimatedTokenCount(for: messages)
        guard let resolvedMaxTokens = maxTokens,
              AgentConversationCompactionPolicy.shouldCompactHistory(
                  usedTokens: rawTokenCount,
                  maxTokens: resolvedMaxTokens,
                  messageCount: conversationMessageCount(in: messages),
                  force: force
              ) else {
            return AgentConversationCompactionResult(
                messages: messages,
                wasCompacted: false,
                originalEstimatedTokenCount: rawTokenCount,
                estimatedTokenCount: rawTokenCount,
                maxTokens: maxTokens,
                compactedSystemPrompt: firstSystemPrompt(in: messages),
                keptRecentMessageCount: conversationMessageCount(in: messages)
            )
        }

        guard let candidate = bestCandidate(
            messages: messages,
            targetTokenCount: AgentConversationCompactionPolicy.targetTokenCount(for: resolvedMaxTokens)
        ) else {
            return AgentConversationCompactionResult(
                messages: messages,
                wasCompacted: false,
                originalEstimatedTokenCount: rawTokenCount,
                estimatedTokenCount: rawTokenCount,
                maxTokens: maxTokens,
                compactedSystemPrompt: firstSystemPrompt(in: messages),
                keptRecentMessageCount: conversationMessageCount(in: messages)
            )
        }

        return AgentConversationCompactionResult(
            messages: candidate.messages,
            wasCompacted: true,
            originalEstimatedTokenCount: rawTokenCount,
            estimatedTokenCount: candidate.estimatedTokenCount,
            maxTokens: resolvedMaxTokens,
            compactedSystemPrompt: candidate.compactedSystemPrompt,
            keptRecentMessageCount: candidate.keptRecentMessageCount
        )
    }

    public static func estimatedTokenCount(
        for messages: [AgentRuntimeMessage]
    ) -> Int {
        let characterCount = messages.reduce(into: 0) { count, message in
            count += message.role.rawValue.count + 12
            count += message.content.count
            count += message.attachments.reduce(into: 0) { attachmentCount, attachment in
                switch attachment.kind {
                case .image:
                    attachmentCount += 512
                case .video:
                    attachmentCount += 1_024
                }
                attachmentCount += attachment.originalFilename.count
            }
        }
        guard characterCount > 0 else {
            return 0
        }
        return max(Int((Double(characterCount) / 4.0).rounded(.up)), 1)
    }

    public static func conversationMemorySummary(
        priorSummary: String?,
        olderMessages: [AgentRuntimeMessage],
        maxCharacters: Int
    ) -> String {
        var lines = [
            """
            \(memorySummaryHeader)
            Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context.
            """
        ]

        if let priorSummary = normalizedPriorSummary(priorSummary) {
            lines.append("Prior memory: \(compactSummaryText(priorSummary, limit: 1_200))")
        }

        for message in olderMessages {
            let content = compactSummaryText(
                message.content,
                limit: summaryLimit(for: message.role)
            )
            if !content.isEmpty {
                lines.append("\(roleLabel(message.role)): \(content)")
            }

            let mediaSummary = mediaSummary(for: message)
            if !mediaSummary.isEmpty {
                lines.append("\(roleLabel(message.role)) media: \(mediaSummary)")
            }
        }

        let summary = lines.joined(separator: "\n")
        guard summary.count > maxCharacters else {
            return summary
        }

        let cutoffIndex = summary.index(summary.startIndex, offsetBy: maxCharacters)
        return String(summary[..<cutoffIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func compactSummaryText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            return ""
        }

        guard normalized.count > limit else {
            return normalized
        }

        let cutoffIndex = normalized.index(normalized.startIndex, offsetBy: limit)
        let truncated = normalized[..<cutoffIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(truncated)..."
    }

    public static func systemPromptWithoutCompactionSummary(
        _ systemPrompt: String
    ) -> String {
        guard let summaryRange = systemPrompt.range(of: memorySummaryHeader) else {
            return systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(systemPrompt[..<summaryRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Candidate {
        var messages: [AgentRuntimeMessage]
        var estimatedTokenCount: Int
        var compactedSystemPrompt: String
        var keptRecentMessageCount: Int
    }

    private static func bestCandidate(
        messages: [AgentRuntimeMessage],
        targetTokenCount: Int
    ) -> Candidate? {
        let split = splitSystemPrompt(from: messages)
        let conversationMessages = split.conversationMessages
        guard conversationMessages.count > AgentConversationCompactionPolicy.minimumRecentMessageCount else {
            return nil
        }

        var recentMessageCount = min(
            AgentConversationCompactionPolicy.defaultRecentMessageCount,
            conversationMessages.count
        )
        var summaryCharacterLimit = AgentConversationCompactionPolicy.maximumSummaryCharacters
        var bestCandidate: Candidate?

        while recentMessageCount >= AgentConversationCompactionPolicy.minimumRecentMessageCount {
            let adjustedRecentMessageCount = adjustedRecentMessageCount(
                in: conversationMessages,
                requestedCount: recentMessageCount
            )
            let splitIndex = max(conversationMessages.count - adjustedRecentMessageCount, 0)
            let olderMessages = Array(conversationMessages.prefix(splitIndex))
            let recentMessages = Array(conversationMessages.suffix(adjustedRecentMessageCount))

            if !olderMessages.isEmpty {
                let summary = conversationMemorySummary(
                    priorSummary: split.priorSummary,
                    olderMessages: olderMessages,
                    maxCharacters: summaryCharacterLimit
                )
                let compactedSystemPrompt = compactedSystemPrompt(
                    systemPrompt: split.baseSystemPrompt,
                    summary: summary
                )
                var candidateMessages: [AgentRuntimeMessage] = []
                if let compactedSystemPrompt = compactedSystemPrompt.nilIfBlank {
                    candidateMessages.append(
                        AgentRuntimeMessage(role: .system, content: compactedSystemPrompt)
                    )
                }
                candidateMessages.append(contentsOf: recentMessages)

                let tokenCount = estimatedTokenCount(for: candidateMessages)
                let candidate = Candidate(
                    messages: candidateMessages,
                    estimatedTokenCount: tokenCount,
                    compactedSystemPrompt: compactedSystemPrompt,
                    keptRecentMessageCount: adjustedRecentMessageCount
                )

                if bestCandidate == nil || tokenCount < (bestCandidate?.estimatedTokenCount ?? .max) {
                    bestCandidate = candidate
                }

                if tokenCount <= targetTokenCount {
                    return candidate
                }
            }

            if recentMessageCount > AgentConversationCompactionPolicy.minimumRecentMessageCount {
                recentMessageCount -= 1
                continue
            }

            if summaryCharacterLimit > AgentConversationCompactionPolicy.minimumSummaryCharacters {
                summaryCharacterLimit = max(
                    AgentConversationCompactionPolicy.minimumSummaryCharacters,
                    Int(Double(summaryCharacterLimit) * 0.7)
                )
                continue
            }

            break
        }

        return bestCandidate
    }

    private static func splitSystemPrompt(
        from messages: [AgentRuntimeMessage]
    ) -> (
        baseSystemPrompt: String?,
        priorSummary: String?,
        conversationMessages: [AgentRuntimeMessage]
    ) {
        guard let first = messages.first, first.role == .system else {
            return (nil, nil, messages)
        }

        return (
            systemPromptWithoutCompactionSummary(first.content).nilIfBlank,
            priorSummary(from: first.content),
            Array(messages.dropFirst())
        )
    }

    private static func compactedSystemPrompt(
        systemPrompt: String?,
        summary: String
    ) -> String {
        [
            systemPrompt.map(systemPromptWithoutCompactionSummary),
            summary
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func priorSummary(from systemPrompt: String) -> String? {
        guard let summaryRange = systemPrompt.range(of: memorySummaryHeader) else {
            return nil
        }
        return String(systemPrompt[summaryRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private static func normalizedPriorSummary(_ summary: String?) -> String? {
        guard var summary = summary?.nilIfBlank else {
            return nil
        }
        if let headerRange = summary.range(of: memorySummaryHeader) {
            summary.removeSubrange(headerRange)
        }
        summary = summary
            .replacingOccurrences(
                of: "Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context.",
                with: ""
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.nilIfBlank
    }

    private static func adjustedRecentMessageCount(
        in messages: [AgentRuntimeMessage],
        requestedCount: Int
    ) -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        var count = min(max(requestedCount, 0), messages.count)
        while count < messages.count {
            let startIndex = messages.count - count
            guard messages[startIndex].role == .tool else {
                break
            }
            count += 1
        }
        return count
    }

    private static func conversationMessageCount(
        in messages: [AgentRuntimeMessage]
    ) -> Int {
        if messages.first?.role == .system {
            return max(messages.count - 1, 0)
        }
        return messages.count
    }

    private static func firstSystemPrompt(
        in messages: [AgentRuntimeMessage]
    ) -> String? {
        guard messages.first?.role == .system else {
            return nil
        }
        return messages.first?.content
    }

    private static func roleLabel(_ role: AgentRuntimeMessage.Role) -> String {
        switch role {
        case .system:
            return "System"
        case .user:
            return "User request"
        case .assistant:
            return "Assistant reply"
        case .tool:
            return "Tool result"
        }
    }

    private static func mediaSummary(for message: AgentRuntimeMessage) -> String {
        let imageCount = message.attachments.filter { $0.kind == .image }.count
        let videoCount = message.attachments.filter { $0.kind == .video }.count
        var parts: [String] = []
        if imageCount > 0 {
            parts.append("\(imageCount) image(s)")
        }
        if videoCount > 0 {
            parts.append("\(videoCount) video(s)")
        }
        return parts.joined(separator: ", ")
    }

    private static func summaryLimit(for role: AgentRuntimeMessage.Role) -> Int {
        switch role {
        case .user:
            return 240
        case .assistant:
            return 360
        case .tool:
            return 320
        case .system:
            return 240
        }
    }
}
