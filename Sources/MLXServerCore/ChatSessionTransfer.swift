//
//  ChatSessionTransfer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

struct ChatSessionTransfer: Sendable {
    let session: MLXServerRawChatSession
}

struct LoadedModelKey: Hashable, Sendable {
    var modelID: String
    var runtimeKind: MLXServerModelRuntimeKind

    var displayName: String {
        "\(modelID) [\(runtimeKind.rawValue)]"
    }
}

struct ModelLoadingTask {
    var id: UUID
    var task: Task<ModelContainer, any Error>
}

public enum MLXServerChatSessionTranscriptText {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

        public static func visibleAssistantContent(from generatedText: String, startsInThinking: Bool) -> String {
        var text = canonicalizedThinkingTags(generatedText)

        if startsInThinking, let closeRange = text.range(of: closeTag) {
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        } else if let closeRange = text.range(of: closeTag),
                  shouldDiscardPrefixThroughCloseTag(in: text, closeRange: closeRange) {
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        }

        var visible = ""
        while !text.isEmpty {
            guard let openRange = text.range(of: openTag) else {
                visible += text
                break
            }

            visible += text[..<openRange.lowerBound]
            text.removeSubrange(text.startIndex..<openRange.upperBound)

            guard let closeRange = text.range(of: closeTag) else {
                break
            }
            text.removeSubrange(text.startIndex..<closeRange.upperBound)

            if let strayCloseRange = text.range(of: closeTag),
               shouldDiscardPrefixThroughCloseTag(in: text, closeRange: strayCloseRange) {
                text.removeSubrange(text.startIndex..<strayCloseRange.upperBound)
            }
        }

        return visible
    }

    public static func visibleAssistantContentForHistory(
        from generatedText: String,
        startsInThinking: Bool
    ) -> String {
                guard startsInThinking else {
            return visibleAssistantContent(from: generatedText, startsInThinking: false)
        }
        let canonicalText = canonicalizedThinkingTags(generatedText)
        guard let closeRange = canonicalText.range(of: closeTag) else {
            return ""
        }

        let visibleStartIndex = closeRange.upperBound
        return visibleAssistantContent(
            from: String(canonicalText[visibleStartIndex...]),
            startsInThinking: false
        )
    }

    public static func assistantHistoryMessages(
        from generatedText: String,
        startsInThinking: Bool,
        preservesThinking: Bool
    ) -> [MLXServerChatMessage] {
        let historyVisibleText = visibleAssistantContentForHistory(
            from: generatedText,
            startsInThinking: startsInThinking
        )
        let reasoningText = reasoningContent(
            from: generatedText,
            startsInThinking: startsInThinking
        )
        let trimmedReasoningText = reasoningText.trimmingCharacters(in: .whitespacesAndNewlines)
        var messages: [MLXServerChatMessage] = []
        if preservesThinking, !trimmedReasoningText.isEmpty {
            messages.append(
                .assistant(
                    MLXServerReasoningTranscript.reasoningSummary(trimmedReasoningText)
                )
            )
        }
        let historyReasoningText = preservesThinking ? trimmedReasoningText : nil
        if !historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || historyReasoningText?.isEmpty == false {
            messages.append(
                .assistant(
                    historyVisibleText,
                    reasoningContent: historyReasoningText
                )
            )
        }
        if messages.isEmpty {
            messages.append(.assistant(""))
        }
        return messages
    }

        public static func reasoningContent(from generatedText: String, startsInThinking: Bool) -> String {

        var text = canonicalizedThinkingTags(generatedText)
        var reasoning = ""

        if startsInThinking {
            if let closeRange = text.range(of: closeTag) {
                reasoning += strippingLeadingOpenTag(
                    String(text[..<closeRange.lowerBound])
                )
                text.removeSubrange(text.startIndex..<closeRange.upperBound)
            }
        }

        while !text.isEmpty {
            guard let openRange = text.range(of: openTag) else {
                break
            }
            text.removeSubrange(text.startIndex..<openRange.upperBound)

            guard let closeRange = text.range(of: closeTag) else {
                reasoning += text
                break
            }

            reasoning += text[..<closeRange.lowerBound]
            text.removeSubrange(text.startIndex..<closeRange.upperBound)
        }

        return reasoning
    }

        /// Normalizes alternate thinking-channel markers (e.g. gemma-4's
    /// `<|channel>thought` / `<channel|>`) to the canonical `<think>` /
    /// `</think>` tags so the shared splitting logic can handle them.
    private static func canonicalizedThinkingTags(_ text: String) -> String {
        guard text.contains("channel") else {
            return text
        }
        return text
            .replacingOccurrences(of: "<|channel>thought", with: openTag)
            .replacingOccurrences(of: "<channel|>", with: closeTag)
    }

    private static func strippingLeadingOpenTag(_ text: String) -> String {
        let trimmedPrefix = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrefix.hasPrefix(openTag),
              let openRange = text.range(of: openTag) else {
            return text
        }
        var text = text
        text.removeSubrange(text.startIndex..<openRange.upperBound)
        return text
    }

    private static func shouldDiscardPrefixThroughCloseTag(
        in text: String,
        closeRange: Range<String.Index>
    ) -> Bool {
        guard let openRange = text.range(of: openTag) else {
            return true
        }
        return openRange.lowerBound > closeRange.lowerBound
    }
}

enum MLXServerToolResultTemplateStyle {
    case roleToolContent
    case toolResponses

    static func style(for model: MLXServerModelDescriptor) -> Self {
        let name = "\(model.id) \(model.displayName)".lowercased()
        return name.contains("gemma") ? .toolResponses : .roleToolContent
    }
}

