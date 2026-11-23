//
//  RemoteGenerationClientImageStrippingTests.swift
//  ZenCODE
//
//  `RemoteGenerationClient.messagesStrippingImageContent`: an image that cannot
//  be sent is replaced by a text notice instead of vanishing, so the model does
//  not believe it saw it. Pure functions, no client, no disk.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Image stripping notice")
struct RemoteGenerationClientImageStrippingTests {
    private let notice = RemoteGenerationClient.omittedImageNotice
    private let imageURL = "data:image/png;base64,AAAA"

    private func text(_ value: String) -> [String: Any] {
        ["type": "text", "text": value]
    }

    private func image(_ url: String? = nil) -> [String: Any] {
        ["type": "image_url", "image_url": ["url": url ?? imageURL]]
    }

    private func strip(
        _ message: [String: Any],
        notice: String? = nil
    ) -> [String: Any] {
        let result = notice.map {
            RemoteGenerationClient.messagesStrippingImageContent(from: [message], notice: $0)
        } ?? RemoteGenerationClient.messagesStrippingImageContent(from: [message])
        return result[0]
    }

    @Test
    func theDefaultNoticeTellsTheModelNotToGuessAndToUseTextTools() {
        #expect(notice.hasPrefix("[Image omitted:"))
        #expect(notice.hasSuffix("]"))
        #expect(notice.contains("cannot receive images"))
        #expect(notice.contains("Do not guess its contents"))
        #expect(notice.contains("text-based tools"))
        let unreadable = RemoteGenerationClient.unreadableImageNotice
        #expect(unreadable.hasPrefix("[Image omitted:"))
        #expect(unreadable.hasSuffix("]"))
        #expect(unreadable.contains("could not be read or encoded"))
        #expect(unreadable.contains("removed the images from this conversation"))
        #expect(unreadable.contains("Do not guess their contents"))
    }

    @Test
    func aMessageMadeOnlyOfAnImageBecomesTheNoticeString() {
        let stripped = strip(["role": "tool", "tool_call_id": "call_1", "content": [image()]])

        #expect(stripped["content"] as? String == notice)
        #expect(stripped["role"] as? String == "tool")
        #expect(stripped["tool_call_id"] as? String == "call_1")
    }

    @Test
    func textAndImageCollapseToOneStringJoinedByABlankLine() {
        let stripped = strip(["role": "tool", "content": [text("Screenshot captured"), image()]])

        #expect(stripped["content"] as? String == "Screenshot captured\n\n\(notice)")
        #expect(!RemoteGenerationClient.messagesContainImageContent([stripped]))
    }

    @Test
    func everyImageGetsItsOwnNoticeInContentOrder() {
        let stripped = strip(["role": "user", "content": [image(), text("between"), image("data:image/png;base64,BBBB")]])

        #expect(stripped["content"] as? String == "\(notice)\n\nbetween\n\n\(notice)")
    }

    @Test
    func aRemainingNonTextBlockKeepsTheContentAnArray() throws {
        let audio: [String: Any] = ["type": "input_audio", "input_audio": ["data": "AAAA", "format": "wav"]]
        let stripped = strip(["role": "user", "content": [text("listen"), image(), audio]])

        let content = try #require(stripped["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["text"] as? String == "listen")
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == notice)
        #expect(content[2]["type"] as? String == "input_audio")
        #expect(!content.contains { ($0["type"] as? String) == "image_url" })
    }

    @Test
    func aCustomNoticeReplacesTheDefaultOne() {
        let stripped = strip(
            ["role": "user", "content": [text("look"), image()]],
            notice: RemoteGenerationClient.unreadableImageNotice
        )

        #expect(stripped["content"] as? String == "look\n\n\(RemoteGenerationClient.unreadableImageNotice)")
    }

    @Test
    func anEmptyNoticeDropsTheImagesWithoutAReplacement() throws {
        let onlyImage = strip(["role": "tool", "content": [image()]], notice: "")
        let withText = strip(["role": "user", "content": [text("look"), image()]], notice: "")

        #expect(onlyImage["content"] as? String == "")
        #expect(withText["content"] as? String == "look")
    }

    @Test
    func aSecondPassChangesNothingAndAddsNoNotice() throws {
        let messages: [[String: Any]] = [
            ["role": "user", "content": [text("look"), image()]],
            ["role": "tool", "content": [image()]],
            ["role": "assistant", "content": "plain"],
        ]

        let once = RemoteGenerationClient.messagesStrippingImageContent(from: messages)
        let twice = RemoteGenerationClient.messagesStrippingImageContent(from: once)

        #expect(once[0]["content"] as? String == "look\n\n\(notice)")
        #expect(once[1]["content"] as? String == notice)
        #expect(twice[0]["content"] as? String == once[0]["content"] as? String)
        #expect(twice[1]["content"] as? String == once[1]["content"] as? String)
        #expect(twice[2]["content"] as? String == "plain")
        #expect(!RemoteGenerationClient.messagesContainImageContent(once))
    }

    @Test
    func messagesWithoutImagesAreReturnedUntouched() throws {
        let twoTexts: [[String: Any]] = [text("a"), text("b")]
        let messages: [[String: Any]] = [
            ["role": "user", "content": "just text"],
            ["role": "user", "content": twoTexts],
            ["role": "assistant", "content": NSNull(), "tool_calls": [["id": "call_1"]]],
        ]

        let stripped = RemoteGenerationClient.messagesStrippingImageContent(from: messages)

        #expect(stripped[0]["content"] as? String == "just text")
        #expect((stripped[1]["content"] as? [[String: Any]])?.count == 2)
        #expect(stripped[2]["content"] is NSNull)
        #expect((stripped[2]["tool_calls"] as? [[String: Any]])?.count == 1)
    }

    @Test
    func otherKeysSurviveAndRawTokensStayOnTheAssistantMessageOnly() {
        let assistant: [String: Any] = [
            "role": "assistant",
            "content": "Hi",
            DS4MessageKeys.rawAssistant: "Hi<raw>",
            DS4MessageKeys.rawTokens: [Int32]([11, 22, 33]),
            DS4MessageKeys.rawTokensModel: "41-2-mock-ds4",
        ]
        let tool: [String: Any] = [
            "role": "tool",
            "tool_call_id": "call_1",
            "name": "fixture.echo",
            "is_error": false,
            DS4MessageKeys.systemReminder: true,
            "content": [text("out"), image()],
        ]

        let stripped = RemoteGenerationClient.messagesStrippingImageContent(from: [assistant, tool])

        // Tokens describe what the model generated, never a user or tool content.
        #expect(DS4MessageKeys.rawTokenIDs(of: tool) == nil)
        #expect(DS4MessageKeys.rawTokenIDs(of: stripped[0]) == [11, 22, 33])
        #expect(stripped[0]["content"] as? String == "Hi")
        #expect(stripped[1]["tool_call_id"] as? String == "call_1")
        #expect(stripped[1]["name"] as? String == "fixture.echo")
        #expect(stripped[1]["is_error"] as? Bool == false)
        #expect(stripped[1][DS4MessageKeys.systemReminder] as? Bool == true)
        #expect(stripped[1]["content"] as? String == "out\n\n\(notice)")
    }

    @Test
    func theFrozenUserContentOfAStrippedMessageReceivesTheNoticeToo() {
        let frozen = "look\nmemory block"
        let message: [String: Any] = [
            "role": "user",
            "content": [text("look"), image()],
            DS4MessageKeys.userContent: frozen,
        ]
        let untouched: [String: Any] = ["role": "user", "content": "plain", DS4MessageKeys.userContent: "plain\nmemory"]

        let stripped = RemoteGenerationClient.messagesStrippingImageContent(from: [message, untouched])

        // The DS4 renderer sends the frozen content instead of `content`.
        #expect(stripped[0][DS4MessageKeys.userContent] as? String == "\(frozen)\n\n\(notice)")
        #expect(DS4TranscriptRenderer.userContent(of: stripped[0]).hasSuffix(notice))
        #expect(stripped[1][DS4MessageKeys.userContent] as? String == "plain\nmemory")
        // A second pass does not repeat it.
        let again = RemoteGenerationClient.messagesStrippingImageContent(from: stripped)
        #expect(again[0][DS4MessageKeys.userContent] as? String == "\(frozen)\n\n\(notice)")
    }
}
