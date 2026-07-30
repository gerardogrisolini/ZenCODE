//
//  ToolResultAttachmentPayloadTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct ToolResultAttachmentPayloadTests {
    private let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    @Test
    func responsesPayloadSendsToolImageAsMultimodalInput() throws {
        let payload = try RemoteGenerationClient.validatedResponsesInputPayload(
            from: [toolMessage()]
        )

        #expect(payload.input.count == 2)
        let output = try #require(payload.input[0] as? [String: Any])
        #expect(output["type"] as? String == "function_call_output")
        #expect(output["call_id"] as? String == "call_screenshot")
        #expect(output["output"] as? String == "Captured screenshot.")

        let imageMessage = try #require(payload.input[1] as? [String: Any])
        #expect(imageMessage["type"] as? String == "message")
        #expect(imageMessage["role"] as? String == "user")
        let content = try #require(imageMessage["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["input_text", "input_image"])
        #expect((content[1]["image_url"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test
    func chatCompletionsPayloadKeepsTextToolResultBeforeImageMessage() throws {
        let expanded = RemoteGenerationClient.chatCompletionsMessagesExpandingToolImages(
            from: [toolMessage()]
        )

        #expect(expanded.count == 2)
        #expect(expanded[0]["role"] as? String == "tool")
        #expect(expanded[0]["content"] as? String == "Captured screenshot.")
        #expect(expanded[1]["role"] as? String == "user")
        let content = try #require(expanded[1]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["text", "image_url"])
        #expect((content[0]["text"] as? String)?.contains("macos.run") == true)
    }

    @Test
    func anthropicPayloadEmbedsImageInsideToolResult() throws {
        let payload = AnthropicSubscriptionGenerationClient.anthropicMessagesPayload(
            from: [toolMessage()]
        )

        #expect(payload.messages.count == 1)
        let outerContent = try #require(payload.messages[0]["content"] as? [[String: Any]])
        let toolResult = try #require(outerContent.first)
        #expect(toolResult["type"] as? String == "tool_result")
        #expect(toolResult["tool_use_id"] as? String == "call_screenshot")
        let resultContent = try #require(toolResult["content"] as? [[String: Any]])
        #expect(resultContent.map { $0["type"] as? String } == ["text", "image"])
        let source = try #require(resultContent[1]["source"] as? [String: Any])
        #expect(source["media_type"] as? String == "image/png")
        #expect(source["data"] as? String == pngData.base64EncodedString())
    }

    @Test
    func snapshotConversionRetainsInlineToolImageBytes() throws {
        let runtimeMessages = RemoteGenerationClient.agentRuntimeMessages(
            from: [toolMessage()]
        )

        let message = try #require(runtimeMessages.first)
        #expect(message.role == .tool)
        #expect(message.content == "Captured screenshot.")
        let attachment = try #require(message.attachments.first)
        #expect(attachment.kind == .image)
        #expect(attachment.contentType == "image/png")
        #expect(attachment.data == pngData)

        let restored = RemoteGenerationClient.initialMessages(
            cwd: "/tmp",
            systemPrompt: "System",
            history: runtimeMessages,
            allowedToolNames: ["macos.run"]
        )
        let restoredTool = try #require(restored.last)
        let restoredImages = RemoteGenerationClient.chatCompletionsImageContentItems(
            from: restoredTool["content"]
        )
        #expect(restoredImages.count == 1)
    }

    private func toolMessage() -> [String: Any] {
        let toolCall = DirectAgentToolCall(
            id: "call_screenshot",
            name: "macos.run",
            argumentsObject: ["action": "screenshot"],
            argumentsJSON: #"{"action":"screenshot"}"#
        )
        let result = DirectAgentToolResult(
            output: "Captured screenshot.",
            summary: "Captured screenshot.",
            attachments: [
                AgentRuntimeAttachment(
                    kind: .image,
                    data: pngData,
                    contentType: "image/png",
                    originalFilename: "terminal.png"
                )
            ]
        )
        return RemoteGenerationClient.toolResultMessage(
            toolCall: toolCall,
            result: result
        )
    }
}
