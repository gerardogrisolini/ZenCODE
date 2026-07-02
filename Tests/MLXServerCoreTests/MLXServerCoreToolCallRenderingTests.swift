//
//  MLXServerCoreTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Testing
@testable import MLXServerCore
import Foundation
import MLXLMCommon
import os

@Test
func chatMessageRendersAssistantToolCallAsStructuredRawPayload() throws {
    let message = MLXServerChatMessage.assistant(
        "",
        toolCalls: [
            MLXServerChatToolCall(
                id: "call_1",
                name: "local.pwd",
                arguments: [
                    "path": "/tmp",
                    "recursive": false
                ]
            )
        ]
    )
    let raw = message.rawTemplateMessage(toolResultStyle: .roleToolContent)
    let toolCalls = try #require(
        raw["tool_calls"] as? [[String: any Sendable]]
    )
    let toolCall = try #require(toolCalls.first)
    let function = try #require(toolCall["function"] as? [String: any Sendable])
    let arguments = try #require(function["arguments"] as? [String: any Sendable])

    #expect(toolCall["id"] as? String == "call_1")
    #expect(toolCall["type"] as? String == "function")
    #expect(function["name"] as? String == "local.pwd")
    #expect(arguments["path"] as? String == "/tmp")
    #expect(arguments["recursive"] as? Bool == false)
}

@Test
func chatMessageRendersQwenToolResultAsRoleToolContent() throws {
    let message = MLXServerChatMessage.tool(
        "result",
        toolCallID: "call_1",
        toolName: "local.pwd"
    )
    let raw = message.rawTemplateMessage(toolResultStyle: .roleToolContent)

    #expect(raw["role"] as? String == "tool")
    #expect(raw["content"] as? String == "result")
    #expect(raw["tool_call_id"] as? String == "call_1")
    #expect(raw["name"] as? String == "local.pwd")
}

@Test
func chatMessageRendersGemmaToolResultAsStructuredToolResponse() throws {
    let message = MLXServerChatMessage.tool(
        "result",
        toolCallID: "call_1",
        toolName: "local.pwd"
    )
    let raw = message.rawTemplateMessage(toolResultStyle: .toolResponses)
    let responses = try #require(
        raw["tool_responses"] as? [[String: any Sendable]]
    )
    let response = try #require(responses.first)

    #expect(raw["role"] as? String == "tool")
    #expect(raw["content"] as? String == "")
    #expect(raw["tool_call_id"] as? String == "call_1")
    #expect(raw["name"] as? String == "local.pwd")
    #expect(response["name"] as? String == "local.pwd")
    #expect(response["response"] as? String == "result")
}

@Test
func toolCallStreamProcessorPreservesSingleLineBeforeSplitTaggedToolCall() throws {
    var processor = MLXServerToolCallStreamProcessor(format: .xmlFunction)

    #expect(processor.processChunk("Analizzo il file <tool") == "Analizzo il file ")
    #expect(processor.drainToolCalls().isEmpty)

    #expect(
        processor.processChunk(
            "_call>\n<function=local.pwd>\n</function>\n</tool_call>"
        ) == nil
    )
    let toolCall = try #require(processor.drainToolCalls().first)
    #expect(toolCall.function.name == "local.pwd")
    #expect(toolCall.function.arguments.isEmpty)
    #expect(processor.processEOS(returnBufferedText: true) == nil)
}

@Test
func toolCallStreamProcessorPreservesTextAroundToolCallAfterThinking() throws {
    var processor = MLXServerToolCallStreamProcessor(format: .xmlFunction)

    #expect(
        processor.processChunk("Ragionamento.</think>\n\n<tool")
            == "Ragionamento.</think>\n\n"
    )
    #expect(processor.drainToolCalls().isEmpty)

    #expect(
        processor.processChunk(
            "_call>\n<function=local.pwd>\n</function>\n</tool_call>Continuo."
        ) == "Continuo."
    )
    let toolCall = try #require(processor.drainToolCalls().first)
    #expect(toolCall.function.name == "local.pwd")
    #expect(processor.processEOS(returnBufferedText: true) == nil)
}

@Test
func toolCallStreamProcessorPreservesTextBetweenConsecutiveToolCalls() throws {
    var processor = MLXServerToolCallStreamProcessor(format: .xmlFunction)

    #expect(
        processor.processChunk(
            """
            Prima <tool_call>
            <function=local.pwd>
            </function>
            </tool_call>Tra<tool_call>
            <function=local.ls>
            </function>
            </tool_call>Dopo
            """
        ) == "Prima TraDopo"
    )
    let toolCalls = processor.drainToolCalls()
    #expect(toolCalls.map(\.function.name) == ["local.pwd", "local.ls"])
    #expect(processor.processEOS(returnBufferedText: true) == nil)
}

@Test
func toolCallStreamProcessorFlushesIncompleteTaggedToolCallAtEnd() {
    var processor = MLXServerToolCallStreamProcessor(format: .xmlFunction)

    #expect(processor.processChunk("Risposta <tool") == "Risposta ")
    #expect(processor.drainToolCalls().isEmpty)
    #expect(processor.processEOS(returnBufferedText: true) == "<tool")
    #expect(processor.drainToolCalls().isEmpty)
}
