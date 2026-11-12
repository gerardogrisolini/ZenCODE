//
//  RemoteGenerationClient+Messages.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension RemoteGenerationClient {
    public static func systemPrompt(cwd: String, allowedToolNames: Set<String>?) -> String {
        AgentStandaloneSystemPrompt.promptSections(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled(allowedToolNames),
            allowedToolNames: allowedToolNames
        )
        .systemPrompt
    }

    public static func initialMessages(
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let seededHistory = history.compactMap(remoteMessage(from:))
        if let firstRole = seededHistory.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            // A persisted pre-split session is a legacy instruction prefix.
            // Preserve it verbatim rather than modifying its cache identity.
            return seededHistory
        }

        let fallbackSections = AgentStandaloneSystemPrompt.promptSections(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled(allowedToolNames),
            allowedToolNames: allowedToolNames
        )
        let resolvedSystemPrompt = systemPrompt?.nilIfBlank
            ?? fallbackSections.systemPrompt
        let fallbackContext = systemPrompt?.nilIfBlank == nil
            ? fallbackSections.dynamicContext
            : nil
        let contextMessage = AgentRuntimeDynamicContext.message(for: fallbackContext)
            .flatMap(remoteMessage(from:))
        return [["role": "system", "content": resolvedSystemPrompt]]
            + (contextMessage.map { [$0] } ?? []) + seededHistory
    }

    /// Private key of a user message held by a session: the text its turn
    /// appended to it when it was sent (the recalled memory block, then the
    /// turn instruction).
    ///
    /// ``recordingTurnAddition(on:block:instruction:)`` stores it when the
    /// prompt enters the session and ``applyingCurrentTurnMemory(to:block:instruction:)``
    /// merges it into every outgoing copy, so a prompt is sent again exactly
    /// as it was first sent and the request prefix a provider caches stays
    /// valid across turns. Snapshots carry it as
    /// `AgentRuntimeMessage.turnAddition` (`agentRuntimeMessages(from:)`) and
    /// ``remoteMessage(from:)`` stores it again, so it also survives a
    /// session rebuilt from its history or loaded from a saved one. The key
    /// itself never reaches a wire: the outgoing copy does not carry it and
    /// the chat-completions wire builder drops it.
    static let turnAdditionKey = "zencode_turn_addition"

    /// `message`, the user message of a new prompt, with the text its turn
    /// appends recorded under ``turnAdditionKey``. The message is returned
    /// unchanged when the turn adds nothing; its content is never touched.
    ///
    /// The default arguments read the task-locals at the *call site*, which is
    /// the `sendPrompt` of a generation client, inside the turn's bindings.
    static func recordingTurnAddition(
        on message: [String: Any],
        block: String? = MemoryTurnContext.currentTurnMemoryBlock,
        instruction: String? = AgentTurnInstructionContext.currentTurnInstruction
    ) -> [String: Any] {
        guard let addition = AgentRuntimeMessage.turnAddition(
            memoryBlock: block,
            instruction: instruction
        ) else {
            return message
        }
        var message = message
        message[turnAdditionKey] = addition
        return message
    }

    /// Returns the outgoing copy of `messages`: every prompt carries the
    /// memory block and the instruction of its own turn.
    ///
    /// This is the single place where automatically recalled memory and the
    /// per-turn instruction (``AgentTurnInstructionContext``) enter a provider
    /// request, and it is shared by every concrete generation client so the
    /// three wire formats cannot drift apart.
    ///
    /// Contract:
    ///
    /// - The appended text is the memory block followed by the instruction,
    ///   each only when it is not blank, joined by a blank line. The memory
    ///   block always comes first and the instruction is the last thing the
    ///   model reads.
    /// - A user message that carries a recorded addition (``turnAdditionKey``)
    ///   gets that addition, on every round and on every later turn, and the
    ///   key is removed from the copy. A prompt is therefore sent again
    ///   exactly as it was first sent: sending it without its block on the
    ///   next turn would change the request from that message on and
    ///   invalidate the prefix the provider cached.
    /// - The last user message gets the current turn's `block` and
    ///   `instruction`, unless that very text is already its recorded
    ///   addition, which is the case of the turn's own prompt. Any other last
    ///   user message receives it: when a compaction removed the prompt of the
    ///   running turn, every round still carries the block.
    /// - The input is returned **unchanged** when there is nothing to merge,
    ///   so a conversation without a block or an instruction produces a
    ///   byte-identical payload.
    /// - Only the outgoing copy is touched. Callers pass `session.messages` by
    ///   value and must never write the result back: the content of a session
    ///   message never holds the block or the instruction, which is what
    ///   keeps them out of the conversation text and the session cache key.
    ///   History and snapshots carry them beside the content, in
    ///   `AgentRuntimeMessage.turnAddition`.
    /// - Multimodal content is preserved: when a user message already carries
    ///   an array of content items (text plus images), the combined text is
    ///   appended as one more `text` item instead of clobbering the array
    ///   with a string, which would silently drop the attached images.
    /// - Callers apply this on **every** tool round, always against the current
    ///   value of `session.messages`, so each round's outgoing copy carries
    ///   every addition exactly once; applying the helper to a previous
    ///   outgoing copy is what would duplicate the current turn's text, and
    ///   call sites never do that.
    ///
    /// The default arguments read the task-locals at the *call site*, which is
    /// what makes the turn-scoped bindings visible here without threading the
    /// block or the instruction through every provider signature.
    public static func applyingCurrentTurnMemory(
        to messages: [[String: Any]],
        block: String? = MemoryTurnContext.currentTurnMemoryBlock,
        instruction: String? = AgentTurnInstructionContext.currentTurnInstruction
    ) -> [[String: Any]] {
        var updated = messages
        for index in messages.indices {
            guard let recorded = messages[index][turnAdditionKey] else {
                continue
            }
            var message = messages[index]
            message.removeValue(forKey: turnAdditionKey)
            if let addition = (recorded as? String)?.nilIfEmpty,
               let merged = appendingTurnAddition(addition, to: message) {
                message = merged
            }
            updated[index] = message
        }

        guard let addition = AgentRuntimeMessage.turnAddition(
                  memoryBlock: block,
                  instruction: instruction
              ),
              let lastUserIndex = messages.lastIndex(where: { message in
                  stringValue(message["role"])?
                      .trimmingCharacters(in: .whitespacesAndNewlines)
                      .lowercased() == "user"
              }),
              // The prompt of the running turn already carries this very
              // text, recorded when it entered the session.
              (messages[lastUserIndex][turnAdditionKey] as? String) != addition,
              let merged = appendingTurnAddition(addition, to: updated[lastUserIndex]) else {
            // Nothing to add, no user message to attach to (a replayed
            // tool-only tail, for example: injecting a synthetic one would
            // change the shape of the conversation), or an unrecognized
            // content shape, left untouched rather than guessing a
            // representation the provider may reject.
            return updated
        }
        updated[lastUserIndex] = merged
        return updated
    }

    /// `message` with `addition` appended to its content, or `nil` when the
    /// content has a shape the text cannot be appended to.
    private static func appendingTurnAddition(
        _ addition: String,
        to message: [String: Any]
    ) -> [String: Any]? {
        var message = message
        if let text = message["content"] as? String {
            message["content"] = text.isEmpty ? addition : "\(text)\n\n\(addition)"
        } else if var items = message["content"] as? [[String: Any]] {
            items.append(["type": "text", "text": addition])
            message["content"] = items
        } else {
            return nil
        }
        return message
    }

    public static func replacingSystemPrompt(
        in messages: [[String: Any]],
        cwd: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let prompt = systemPrompt?.nilIfBlank
            ?? Self.systemPrompt(cwd: cwd, allowedToolNames: allowedToolNames)
        var updatedMessages = messages
        if let firstRole = updatedMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            updatedMessages[0] = ["role": "system", "content": prompt]
        } else {
            updatedMessages.insert(["role": "system", "content": prompt], at: 0)
        }
        return updatedMessages
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func remoteMessage(from message: AgentRuntimeMessage) -> [String: Any]? {
        var payload = remoteMessage(
            role: message.role.rawValue,
            content: message.content,
            attachments: message.attachments
        )
        if message.role == .assistant, !message.toolCalls.isEmpty {
            payload["tool_calls"] = message.toolCalls.map { toolCall in
                [
                    "id": toolCall.id ?? "call_\(UUID().uuidString.lowercased())",
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }
        if message.role == .assistant {
            let replayFields: [(String, String?)] = [
                ("reasoning_content", message.reasoningContent),
                ("reasoning_items", message.reasoningItemsJSON),
                ("thinking_blocks", message.thinkingBlocksJSON),
                ("anthropic_content_blocks", message.anthropicContentBlocksJSON),
                ("response_id", message.providerResponseID),
            ]
            for (key, value) in replayFields {
                if let value = value?.nilIfBlank { payload[key] = value }
            }
        }
        if message.role == .tool {
            if let toolCallID = message.toolCallID {
                payload["tool_call_id"] = toolCallID
            }
            if let toolName = message.toolName {
                payload["name"] = toolName
            }
            if message.toolResultIsError == true {
                payload["is_error"] = true
            }
        }
        // A prompt keeps what its turn appended when it was first sent, so a
        // session rebuilt from its history sends it again unchanged.
        if let turnAddition = message.turnAddition?.nilIfEmpty {
            payload[turnAdditionKey] = turnAddition
        }
        guard responseMessagePayloadHasContent(payload) else {
            return nil
        }
        return payload
    }

    public static func remoteMessage(
        role: String,
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> [String: Any] {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedContent = promptContent(content, role: normalizedRole, attachments: attachments)
        return [
            "role": normalizedRole.isEmpty ? "user" : normalizedRole,
            "content": chatCompletionsContentPayload(content: normalizedContent, attachments: attachments)
        ]
    }

    public static func toolResultMessage(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> [String: Any] {
        var message: [String: Any] = [
            "role": "tool",
            "tool_call_id": toolCall.id,
            "name": toolCall.name,
            "content": chatCompletionsContentPayload(
                content: result.modelOutput,
                attachments: result.attachments
            )
        ]
        if result.isFailure { message["is_error"] = true }
        return message
    }

    public static func promptContent(
        _ content: String,
        role: String,
        attachments: [AgentRuntimeAttachment]
    ) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user", text.isEmpty, !attachments.isEmpty else {
            return text
        }
        return "Analyze the attached media."
    }

    /// Strips internal reasoning replay metadata from chat-completions history
    /// messages so the wire payload stays within the OpenAI schema.
    ///
    /// `reasoning_items`, `thinking_blocks`, `anthropic_content_blocks`,
    /// `is_error`, and response IDs are internal replay fields for the
    /// Responses/Anthropic endpoints; on `/chat/completions` providers such as
    /// DeepSeek tokenize (and bill) unsupported fields as prompt content. `reasoning_content` is kept only on assistant
    /// tool-call messages of the current round (after the last user message),
    /// matching the DeepSeek thinking-mode tool-call replay contract; the CoT
    /// of previous rounds must not be re-sent.
    ///
    /// When `requiresReasoningContentPlaceholder` is true (DeepSeek), assistant
    /// messages whose reasoning is dropped keep an empty `reasoning_content`
    /// field: the DeepSeek thinking mode rejects replayed assistant messages
    /// that omit the field entirely.
    public static func chatCompletionsWireHistoryMessages(
        from messages: [[String: Any]],
        requiresReasoningContentPlaceholder: Bool = false
    ) -> [[String: Any]] {
        chatCompletionsWireHistoryMessages(
            from: messages,
            replayPolicy: .currentToolRound(requiresPlaceholder: requiresReasoningContentPlaceholder)
        )
    }

    public static func chatCompletionsWireHistoryMessages(
        from messages: [[String: Any]],
        replayPolicy: AgentChatCompletionsReplayPolicy
    ) -> [[String: Any]] {
        let lastUserIndex = messages.lastIndex { message in
            stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        }
        return messages.enumerated().compactMap { index, message -> [String: Any]? in
            var message = message
            message.removeValue(forKey: "reasoning_items")
            message.removeValue(forKey: "thinking_blocks")
            message.removeValue(forKey: "anthropic_content_blocks")
            message.removeValue(forKey: "response_id")
            message.removeValue(forKey: "provider_response_id")
            // `is_error` is internal replay metadata for Anthropic's
            // `tool_result` block. OpenAI-compatible tool messages do not admit
            // it at the message level.
            message.removeValue(forKey: "is_error")
            // Private replay data of the in-process DS4 path never reaches a wire payload.
            message = DS4MessageKeys.removingPrivateKeys(from: message)
            // Neither does a recorded turn addition: the outgoing copy has
            // already merged it into the content.
            message.removeValue(forKey: turnAdditionKey)

            let role = stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let preservesReasoning: Bool
            let requiresPlaceholder: Bool
            switch replayPolicy {
            case .stripReasoning:
                preservesReasoning = false
                requiresPlaceholder = false
            case let .currentToolRound(placeholder):
                let isCurrentRound = lastUserIndex.map { index > $0 } ?? false
                let hasToolCalls = !((message["tool_calls"] as? [[String: Any]])?.isEmpty ?? true)
                preservesReasoning = isCurrentRound && hasToolCalls
                requiresPlaceholder = placeholder
            case .preserveAllAssistantReasoning:
                preservesReasoning = role == "assistant"
                requiresPlaceholder = false
            }
            if !preservesReasoning {
                message.removeValue(forKey: "reasoning_content")
            }

            if role == "assistant", !responseMessagePayloadHasContent(message) {
                return nil
            }
            if role == "assistant",
               requiresPlaceholder,
               message["reasoning_content"] == nil {
                message["reasoning_content"] = ""
            }
            return message
        }
    }

    public static func responseMessagePayloadHasContent(_ message: [String: Any]) -> Bool {
        if let content = contentString(from: message["content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return true
        }

        return !chatCompletionsImageContentItems(from: message["content"]).isEmpty
            || responseReasoningText(from: message) != nil
            || stringValue(message["thinking_blocks"])?.nilIfBlank != nil
            || stringValue(message["anthropic_content_blocks"])?.nilIfBlank != nil
            || !((message["tool_calls"] as? [[String: Any]])?.isEmpty ?? true)
    }

    public static func chatCompletionsContentPayload(
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> Any {
        let imageItems = imageDataURLs(from: attachments).map { dataURL in
            ["type": "image_url", "image_url": ["url": dataURL]]
        }
        guard !imageItems.isEmpty else {
            return content
        }

        var items: [[String: Any]] = []
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(["type": "text", "text": content])
        }
        items.append(contentsOf: imageItems)
        return items
    }

    /// Chat Completions tool messages accept text output but not image content
    /// parts. Preserve each function result as a tool message, then emit its
    /// images in one user message after the contiguous tool-result group.
    public static func chatCompletionsMessagesExpandingToolImages(
        from messages: [[String: Any]]
    ) -> [[String: Any]] {
        var expanded: [[String: Any]] = []
        var pendingImageItems: [[String: Any]] = []

        func flushPendingImages() {
            guard !pendingImageItems.isEmpty else {
                return
            }
            expanded.append(["role": "user", "content": pendingImageItems])
            pendingImageItems.removeAll(keepingCapacity: true)
        }

        for message in messages {
            let role = stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard role == "tool" else {
                flushPendingImages()
                expanded.append(message)
                continue
            }

            let imageItems = chatCompletionsImageContentItems(from: message["content"])
            guard !imageItems.isEmpty else {
                expanded.append(message)
                continue
            }

            var textOnlyToolMessage = message
            textOnlyToolMessage["content"] = contentString(from: message["content"]) ?? ""
            expanded.append(textOnlyToolMessage)
            pendingImageItems.append([
                "type": "text",
                "text": toolGeneratedMediaLabel(from: message)
            ])
            pendingImageItems.append(contentsOf: imageItems)
        }

        flushPendingImages()
        return expanded
    }
}
