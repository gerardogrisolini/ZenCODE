//
//  ChatCompletionsHistorySanitizationTests.swift
//  ZenCODE
//
//  Verifies that chat-completions wire history strips internal reasoning
//  replay metadata (which providers such as DeepSeek would tokenize and bill)
//  while preserving the current-round tool-call reasoning replay contract.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ChatCompletionsHistorySanitizationTests {
    @Test
    func stripsInternalReasoningMetadataFromHistory() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "user", "content": "first question"],
            [
                "role": "assistant",
                "content": "first answer",
                "reasoning_content": "old chain of thought",
                "reasoning_items": "[{\"type\":\"reasoning\"}]",
                "thinking_blocks": "[{\"type\":\"thinking\"}]",
                "response_id": "resp_123"
            ],
            ["role": "user", "content": "second question"]
        ]

        let sanitized = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages
        )

        #expect(sanitized.count == 4)
        let assistant = sanitized[2]
        #expect(assistant["reasoning_content"] == nil)
        #expect(assistant["reasoning_items"] == nil)
        #expect(assistant["thinking_blocks"] == nil)
        #expect(assistant["response_id"] == nil)
        #expect(assistant["content"] as? String == "first answer")
    }

    @Test
    func keepsCurrentRoundToolCallReasoningContent() {
        let toolCalls: [[String: Any]] = [
            [
                "id": "call_1",
                "type": "function",
                "function": ["name": "tool_local_ls", "arguments": "{}"]
            ]
        ]
        let messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "user", "content": "question"],
            [
                "role": "assistant",
                "content": "",
                "reasoning_content": "current round reasoning",
                "tool_calls": toolCalls
            ],
            [
                "role": "tool",
                "content": "tool output",
                "tool_call_id": "call_1",
                "name": "tool_local_ls"
            ]
        ]

        let sanitized = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages
        )

        #expect(sanitized.count == 4)
        let assistant = sanitized[2]
        #expect(assistant["reasoning_content"] as? String == "current round reasoning")
        #expect((assistant["tool_calls"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func dropsPreviousRoundReasoningEvenWithToolCalls() {
        let toolCalls: [[String: Any]] = [
            [
                "id": "call_1",
                "type": "function",
                "function": ["name": "tool_local_ls", "arguments": "{}"]
            ]
        ]
        let messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "user", "content": "first question"],
            [
                "role": "assistant",
                "content": "",
                "reasoning_content": "previous round reasoning",
                "tool_calls": toolCalls
            ],
            [
                "role": "tool",
                "content": "tool output",
                "tool_call_id": "call_1",
                "name": "tool_local_ls"
            ],
            ["role": "assistant", "content": "first answer"],
            ["role": "user", "content": "second question"]
        ]

        let sanitized = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages
        )

        let assistant = sanitized[2]
        #expect(assistant["reasoning_content"] == nil)
        #expect((assistant["tool_calls"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func addsEmptyReasoningContentPlaceholderWhenRequired() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "user", "content": "first question"],
            [
                "role": "assistant",
                "content": "first answer",
                "reasoning_content": "old chain of thought"
            ],
            ["role": "user", "content": "second question"]
        ]

        let sanitized = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages,
            requiresReasoningContentPlaceholder: true
        )

        let assistant = sanitized[2]
        #expect(assistant["reasoning_content"] as? String == "")
        let system = sanitized[0]
        #expect(system["reasoning_content"] == nil)
        let user = sanitized[1]
        #expect(user["reasoning_content"] == nil)
    }

    @Test
    func responsesInputDropsPreviousRoundLooseReasoningText() throws {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "prompt"],
            ["role": "user", "content": "first question"],
            [
                "role": "assistant",
                "content": "first answer",
                "reasoning_content": "old chain of thought"
            ],
            ["role": "user", "content": "second question"],
            [
                "role": "assistant",
                "content": "",
                "reasoning_content": "current round reasoning",
                "tool_calls": [
                    [
                        "id": "call_1",
                        "type": "function",
                        "function": ["name": "tool_local_ls", "arguments": "{}"]
                    ] as [String: Any]
                ]
            ]
        ]

        let payload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let items = payload.input.compactMap { $0 as? [String: Any] }
        let reasoningItems = items.filter { ($0["type"] as? String) == "reasoning" }

        #expect(reasoningItems.count == 1)
        let content = reasoningItems.first?["content"] as? [[String: Any]]
        #expect(content?.first?["text"] as? String == "current round reasoning")
    }

    @Test
    func responsesInputKeepsStructuredReasoningItemsForAllRounds() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "first question"],
            [
                "role": "assistant",
                "content": "first answer",
                "reasoning_items": "[{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"abc\",\"summary\":[]}]"
            ],
            ["role": "user", "content": "second question"]
        ]

        let payload = RemoteGenerationClient.responsesInputPayload(from: messages)
        let items = payload.input.compactMap { $0 as? [String: Any] }
        let reasoningItems = items.filter { ($0["type"] as? String) == "reasoning" }

        #expect(reasoningItems.count == 1)
        #expect(reasoningItems.first?["id"] as? String == "rs_1")
        #expect(reasoningItems.first?["encrypted_content"] as? String == "abc")
    }

    @Test
    func dropsAssistantMessagesLeftWithoutContentAfterSanitization() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "question"],
            [
                "role": "assistant",
                "content": "",
                "reasoning_content": "reasoning only, no answer"
            ],
            ["role": "user", "content": "follow-up"]
        ]

        let sanitized = RemoteGenerationClient.chatCompletionsWireHistoryMessages(
            from: messages
        )

        #expect(sanitized.count == 2)
        #expect(sanitized.allSatisfy { ($0["role"] as? String) == "user" })
    }
}
