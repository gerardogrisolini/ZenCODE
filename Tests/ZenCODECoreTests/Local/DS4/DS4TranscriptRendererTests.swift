//
//  DS4TranscriptRendererTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("DS4 transcript renderer")
struct DS4TranscriptRendererTests {
    private static let tools = "## Tools\n\nfixture"

    private static func context(
        _ syntax: DS4ToolSyntax,
        thinkMode: Int32 = DS4EngineABI.ThinkMode.none,
        preserveThinking: Bool = false,
        tools: String = tools,
        tokenIdentity: String? = nil
    ) -> DS4TranscriptRenderer.Context {
        DS4TranscriptRenderer.Context(
            syntax: syntax,
            thinkMode: thinkMode,
            toolsPrompt: tools,
            preserveThinking: preserveThinking,
            tokenIdentity: tokenIdentity
        )
    }

    @Test
    func systemPartFollowsDS4AgentForEverySyntax() {
        let system = DS4TranscriptOperation.message(role: "system", content: "\n\nSYS")
        #expect(DS4TranscriptRenderer.systemOperations(systemPrompt: "SYS", context: Self.context(.dsml)) == [
            .begin, .thinkPrefix(mode: 0), .renderedChat(Self.tools), system,
        ])
        #expect(DS4TranscriptRenderer.systemOperations(systemPrompt: "SYS", context: Self.context(.dsml41)) == [
            .begin, .thinkPrefix(mode: 0), .message(role: "system", content: ""), .renderedChat(Self.tools), system,
        ])
        #expect(DS4TranscriptRenderer.systemOperations(systemPrompt: "SYS", context: Self.context(.glm)) == [
            .begin, .thinkPrefix(mode: 0), .message(role: "system", content: Self.tools), system,
        ])
        #expect(DS4TranscriptRenderer.systemOperations(
            systemPrompt: "SYS",
            context: Self.context(.qwen, thinkMode: DS4EngineABI.ThinkMode.high)
        ) == [
            .begin,
            .message(role: "system", content: DS4ThinkModeMapping.qwenReasoningEffortXHigh),
            .message(role: "system", content: Self.tools),
            system,
        ])
        // Without tools nothing is rendered for them (no empty 4.1 system).
        #expect(DS4TranscriptRenderer.systemOperations(
            systemPrompt: "SYS",
            context: Self.context(.dsml41, tools: "")
        ) == [.begin, .thinkPrefix(mode: 0), system])
    }

    @Test
    func contiguousToolResultsBecomeOneObservation() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "go"],
            ["role": "assistant", "content": "", "tool_calls": [
                ["id": "a", "type": "function", "function": ["name": "one", "arguments": "{}"]],
                ["id": "b", "type": "function", "function": ["name": "two", "arguments": "{}"]],
            ]],
            ["role": "tool", "tool_call_id": "a", "name": "one", "content": "first"],
            ["role": "tool", "tool_call_id": "b", "name": "two", "content": "second\n"],
        ]
        let rendered = DS4TranscriptRenderer.render(messages: messages, context: Self.context(.dsml))
        #expect(rendered.operations.contains(.message(
            role: "tool",
            content: "Tool result 1 (one):\nfirst\nTool result 2 (two):\nsecond\n"
        )))
        #expect(rendered.operations.filter { if case .message("tool", _) = $0 { true } else { false } }.count == 1)
        #expect(rendered.lastMessageIndex == 4)
        #expect(rendered.operations.last == .assistantPrefix(mode: 0))
    }

    @Test
    func rawAssistantTurnsAreReplayedVerbatim() {
        let messages: [[String: Any]] = [
            ["role": "user", "content": "hi"],
            [
                "role": "assistant",
                "content": "visible",
                DS4MessageKeys.rawAssistant: "thinking</think>visible",
                DS4MessageKeys.thinkMode: Int(DS4EngineABI.ThinkMode.high),
                DS4MessageKeys.toolObservation: "Tool error: x\n",
            ],
        ]
        let dsml = DS4TranscriptRenderer.render(
            messages: messages,
            context: Self.context(.dsml, thinkMode: DS4EngineABI.ThinkMode.none)
        )
        #expect(Array(dsml.operations.suffix(5)) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .renderedChat("thinking</think>visible"),
            .endOfSequence,
            .message(role: "tool", content: "Tool error: x\n"),
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
        ])
        // GLM turns end with the next role marker, not EOS.
        let glm = DS4TranscriptRenderer.render(messages: messages, context: Self.context(.glm))
        #expect(!glm.operations.contains(.endOfSequence))
    }

    @Test
    func generatedTurnsReplayTheirExactTokenIDsOnlyForTheSameModel() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "visible",
            DS4MessageKeys.rawAssistant: "thinking</think>visible",
            DS4MessageKeys.rawTokens: [Int32]([5, 6, 7]),
            DS4MessageKeys.rawTokensModel: "41-2-mock-ds4",
            DS4MessageKeys.thinkMode: Int(DS4EngineABI.ThinkMode.high),
        ]
        // Same model: the ids stand in for the text, EOS still ends the turn.
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: message,
            context: Self.context(.dsml, tokenIdentity: "41-2-mock-ds4")
        ) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .tokens([5, 6, 7]),
            .endOfSequence,
        ])
        // GLM ends the turn with the next role marker: the ids are replayed all the same.
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: message,
            context: Self.context(.glm, tokenIdentity: "41-2-mock-ds4")
        ) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .tokens([5, 6, 7]),
        ])

        // Another model (any part of the identity), or an engine with no
        // identity, keeps the textual fallback.
        let fallback: [DS4TranscriptOperation] = [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .renderedChat("thinking</think>visible"),
            .endOfSequence,
        ]
        for identity in ["42-2-mock-ds4", "41-3-mock-ds4", "41-2-other", nil] as [String?] {
            #expect(DS4TranscriptRenderer.assistantOperations(
                for: message,
                context: Self.context(.dsml, tokenIdentity: identity)
            ) == fallback)
        }

        // Ids without the model that produced them are never replayed.
        var anonymous = message
        anonymous.removeValue(forKey: DS4MessageKeys.rawTokensModel)
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: anonymous,
            context: Self.context(.dsml, tokenIdentity: "41-2-mock-ds4")
        ) == fallback)
        // A turn with empty ids replays its text.
        var empty = message
        empty[DS4MessageKeys.rawTokens] = [Int32]()
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: empty,
            context: Self.context(.dsml, tokenIdentity: "41-2-mock-ds4")
        ) == fallback)
    }

    @Test
    func aGeneratedTurnWithOnlyIDsStillReplaysThem() {
        // A turn whose tokens decode to no text keeps its KV tokens in the prompt.
        let messages: [[String: Any]] = [
            ["role": "user", "content": "hi"],
            [
                "role": "assistant",
                "content": "",
                DS4MessageKeys.rawAssistant: "",
                DS4MessageKeys.rawTokens: [Int32]([9]),
                DS4MessageKeys.rawTokensModel: "m",
                DS4MessageKeys.thinkMode: Int(DS4EngineABI.ThinkMode.none),
            ],
        ]
        let rendered = DS4TranscriptRenderer.render(
            messages: messages,
            context: Self.context(.dsml41, tokenIdentity: "m")
        )
        #expect(Array(rendered.operations.suffix(4)) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
            .tokens([9]),
            .endOfSequence,
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
        ])
    }

    @Test
    func synthesizedAssistantTurnsUseReasoningOnlyWhenPreserved() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "answer",
            "reasoning_content": "why",
            "tool_calls": [["id": "a", "type": "function", "function": ["name": "fixture.echo", "arguments": #"{"text":"hi"}"#]]],
        ]
        let calls = DS4ToolCallRenderer.renderToolCalls(
            [DS4ToolCallReplay(name: "fixture.echo", argumentsJSON: #"{"text":"hi"}"#)],
            syntax: .dsml,
            hasContent: true
        )
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: message,
            context: Self.context(.dsml, preserveThinking: true)
        ) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .renderedChat("why</think>answer" + calls),
            .endOfSequence,
        ])
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: message,
            context: Self.context(.dsml, preserveThinking: false)
        ) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
            .renderedChat("answer" + calls),
            .endOfSequence,
        ])
        // Qwen closes the think block like its template.
        #expect(DS4TranscriptRenderer.assistantOperations(
            for: ["role": "assistant", "content": "answer", "reasoning_content": " why "],
            context: Self.context(.qwen, preserveThinking: true)
        ) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.high),
            .renderedChat("why\n</think>\n\nanswer"),
            .endOfSequence,
        ])
    }

    @Test
    func storedReplaysKeepTheEmittedArgumentOrder() {
        let message: [String: Any] = [
            "role": "assistant",
            "content": "",
            "tool_calls": [["id": "a", "type": "function", "function": ["name": "t", "arguments": #"{"a":1,"b":2}"#]]],
            DS4MessageKeys.toolCallReplays: [["name": "t", "arguments": #"{"b":2,"a":1}"#]],
        ]
        let expected = DS4ToolCallRenderer.renderToolCalls(
            [DS4ToolCallReplay(name: "t", argumentsJSON: #"{"b":2,"a":1}"#)],
            syntax: .glm
        )
        #expect(DS4TranscriptRenderer.assistantOperations(for: message, context: Self.context(.glm)) == [
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
            .renderedChat(expected),
        ])
    }

    @Test
    func frozenUserContentAndRemindersAreRenderedInPlace() {
        let messages: [[String: Any]] = [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "first"],
            ["role": "user", "content": "second", DS4MessageKeys.userContent: "second\n\nMEMORY", DS4MessageKeys.systemReminder: true],
            ["role": "user", "content": "third"],
        ]
        let context = Self.context(.dsml)
        let rendered = DS4TranscriptRenderer.render(messages: messages, context: context)
        let system = DS4TranscriptRenderer.systemOperations(systemPrompt: "SYS", context: context)
        let reminder = DS4TranscriptRenderer.reminderOperations(systemPrompt: "SYS", context: context)
        #expect(reminder == [
            .renderedChat("\n\n[System prompt reminder follows.]\n" + Self.tools + "[End system prompt reminder.]\n\n"),
            .message(role: "system", content: "SYS"),
        ])
        #expect(rendered.operations == system + [
            .message(role: "user", content: "first"),
            .message(role: "user", content: "second\n\nMEMORY"),
        ] + reminder + [
            .message(role: "user", content: "third"),
            .assistantPrefix(mode: 0),
        ])
        // The anchor moves past the last reminder.
        #expect(rendered.reminderAnchorOperationCount == system.count + 2 + reminder.count)

        // Without a reminder the anchor is the end of the first user message.
        let plain = DS4TranscriptRenderer.render(messages: [messages[0], messages[1], messages[3]], context: context)
        #expect(plain.reminderAnchorOperationCount == system.count + 1)
        // GLM/Qwen send the reminder as a system message.
        #expect(DS4TranscriptRenderer.reminderOperations(systemPrompt: nil, context: Self.context(.qwen)) == [
            .message(
                role: "system",
                content: "\n\n[System prompt reminder follows.]\n" + Self.tools + "[End system prompt reminder.]\n\n"
            ),
        ])
    }
}

@Suite("DS4 think mode mapping")
struct DS4ThinkModeMappingTests {
    private static func level(_ value: Int32) -> Int32 {
        DS4EngineABI.ThinkMode.levelBase + value
    }

    @Test
    func deepSeek41UsesExplicitEffortLevels() {
        let parse: (String) -> Int32? = { Int32($0).map(Self.level) }
        let expected: [(AgentThinkingSelection?, Int32)] = [
            (.off, DS4EngineABI.ThinkMode.none),
            (.minimal, Self.level(10)),
            (.low, Self.level(25)),
            (.medium, Self.level(50)),
            (.enabled, Self.level(75)),
            (.high, Self.level(75)),
            (.xhigh, Self.level(90)),
            (.max, Self.level(100)),
            (.ultra, Self.level(100)),
            (nil, Self.level(75)),
        ]
        for (selection, mode) in expected {
            #expect(DS4ThinkModeMapping.requestedMode(for: selection, syntax: .dsml41, parseLevel: parse) == mode)
        }
    }

    @Test(arguments: [DS4ToolSyntax.dsml, .glm, .qwen])
    func otherModelsUseNamedModes(_ syntax: DS4ToolSyntax) {
        let parse: (String) -> Int32? = { _ in Issue.record("levels are V4.1 only"); return nil }
        let expected: [(AgentThinkingSelection?, Int32)] = [
            (.off, DS4EngineABI.ThinkMode.none),
            (.minimal, DS4EngineABI.ThinkMode.low),
            (.low, DS4EngineABI.ThinkMode.low),
            (.medium, DS4EngineABI.ThinkMode.medium),
            (.enabled, DS4EngineABI.ThinkMode.high),
            (.high, DS4EngineABI.ThinkMode.high),
            (.xhigh, DS4EngineABI.ThinkMode.high),
            (.max, DS4EngineABI.ThinkMode.max),
            (.ultra, DS4EngineABI.ThinkMode.max),
            (nil, DS4EngineABI.ThinkMode.high),
        ]
        for (selection, mode) in expected {
            #expect(DS4ThinkModeMapping.requestedMode(for: selection, syntax: syntax, parseLevel: parse) == mode)
        }
    }

    @Test
    func effectiveModeGoesThroughThinkModeForContext() async {
        let engine = MockDS4Engine(configuration: .mock(contextSize: 65_536))
        let mode = await DS4ThinkModeMapping.effectiveMode(for: .max, syntax: .dsml, engine: engine, contextSize: 65_536)
        #expect(mode == DS4EngineABI.ThinkMode.high)
        #expect(engine.calls.contains(.thinkModeForContext(mode: DS4EngineABI.ThinkMode.max, contextSize: 65_536)))
    }

    @Test
    func enabledModesAndQwenEffortTexts() {
        #expect(!DS4ThinkModeMapping.isEnabled(DS4EngineABI.ThinkMode.none))
        #expect(DS4ThinkModeMapping.isEnabled(DS4EngineABI.ThinkMode.low))
        #expect(DS4ThinkModeMapping.isEnabled(DS4EngineABI.ThinkMode.max))
        #expect(DS4ThinkModeMapping.isEnabled(Self.level(1)))
        #expect(!DS4ThinkModeMapping.isEnabled(Self.level(0)))
        #expect(DS4ThinkModeMapping.qwenReasoningEffortText(for: DS4EngineABI.ThinkMode.high)
            == DS4ThinkModeMapping.qwenReasoningEffortXHigh)
        #expect(DS4ThinkModeMapping.qwenReasoningEffortText(for: DS4EngineABI.ThinkMode.max)
            == DS4ThinkModeMapping.qwenReasoningEffortXHigh)
        #expect(DS4ThinkModeMapping.qwenReasoningEffortText(for: DS4EngineABI.ThinkMode.low)
            == DS4ThinkModeMapping.qwenReasoningEffortLow)
        #expect(DS4ThinkModeMapping.qwenReasoningEffortText(for: DS4EngineABI.ThinkMode.medium) == nil)
        #expect(DS4ThinkModeMapping.qwenReasoningEffortText(for: DS4EngineABI.ThinkMode.none) == nil)
        #expect(DS4ThinkModeMapping.qwenReasoningEffortXHigh.hasPrefix("Reasoning effort is set to xhigh."))
    }
}

@Suite("DS4 compaction policy")
struct DS4CompactionPolicyTests {
    @Test
    func reserveAndSummaryBudgetFollowDS4Agent() {
        #expect(DS4CompactionPolicy.summaryBudget(contextSize: 1024) == 256)
        #expect(DS4CompactionPolicy.summaryBudget(contextSize: 16_384) == 2048)
        #expect(DS4CompactionPolicy.summaryBudget(contextSize: 1_000_000) == 4096)
        #expect(DS4CompactionPolicy.reserveTokens(compactionPromptTokens: 300, contextSize: 65_536) == 300 + 64 + 4096)
        #expect(DS4CompactionPolicy.compactionPrompt(reason: "why").hasSuffix("\nCompaction reason: why\n"))
        #expect(DS4CompactionPolicy.reserveTranscript.last == .assistantPrefix(mode: DS4EngineABI.ThinkMode.none))
    }

    @Test
    func compactsAtEightyFivePercentOrWhenFreeRoomIsLow() {
        let reserve = 4460
        // 85% of 65536 = 55705.
        #expect(!DS4CompactionPolicy.shouldCompact(usedTokens: 55_000, contextSize: 65_536, reserveTokens: reserve))
        #expect(DS4CompactionPolicy.shouldCompact(usedTokens: 55_706, contextSize: 65_536, reserveTokens: reserve))
        // Small context: the free threshold is max(min(8192, ctx/8), reserve + 128).
        #expect(DS4CompactionPolicy.shouldCompact(usedTokens: 2600, contextSize: 4096, reserveTokens: 1400))
        #expect(!DS4CompactionPolicy.shouldCompact(usedTokens: 2500, contextSize: 4096, reserveTokens: 1400))
        #expect(!DS4CompactionPolicy.shouldCompact(usedTokens: 0, contextSize: 4096, reserveTokens: 1400))
    }

    @Test
    func generationLimitIsBoundedByOutputLimitAndRoom() {
        #expect(DS4CompactionPolicy.generationTokenLimit(
            maxOutputTokens: nil, contextSize: 200_000, usedTokens: 1000, reserveTokens: 4000
        ) == 50_000)
        #expect(DS4CompactionPolicy.generationTokenLimit(
            maxOutputTokens: 300, contextSize: 200_000, usedTokens: 1000, reserveTokens: 4000
        ) == 300)
        #expect(DS4CompactionPolicy.generationTokenLimit(
            maxOutputTokens: nil, contextSize: 8192, usedTokens: 6000, reserveTokens: 1400
        ) == 792)
        #expect(DS4CompactionPolicy.generationTokenLimit(
            maxOutputTokens: nil, contextSize: 8192, usedTokens: 7000, reserveTokens: 1400
        ) <= 0)
    }
}
