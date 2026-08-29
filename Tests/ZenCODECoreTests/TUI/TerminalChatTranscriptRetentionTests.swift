//
//  TerminalChatTranscriptRetentionTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalChatTranscriptRetentionTests {
    @Test
    func boundedTranscriptKeepsAContiguousRecentSuffixWithinBudget() throws {
        let messages = (0..<20).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "message-\(index)-" + String(repeating: "x", count: 400),
                reasoningContent: String(repeating: "r", count: 200)
            )
        }
        let maximumBytes = 4_096

        let bounded = TerminalChat.boundedActiveSessionTranscript(
            messages,
            maximumBytes: maximumBytes
        )

        let notice = try #require(bounded.first)
        #expect(notice.role == .system)
        #expect(notice.content.contains("transcript omitted"))
        #expect(bounded.count < messages.count)
        #expect(bounded.last?.content == messages.last?.content)
        #expect(
            TerminalChat.transcriptRetainedByteCount(bounded) <= maximumBytes
        )
    }

    @Test
    func oversizedNewestAttachmentIsNotRetainedByPresentationTranscript() throws {
        let oversizedAttachment = AgentRuntimeAttachment(
            kind: .image,
            data: Data(repeating: 0x41, count: 8_192),
            contentType: "image/png",
            originalFilename: "large.png"
        )
        let messages = [
            AgentRuntimeMessage(role: .user, content: "small"),
            AgentRuntimeMessage(
                role: .user,
                content: "oversized",
                attachments: [oversizedAttachment]
            ),
        ]
        let maximumBytes = 1_024

        let bounded = TerminalChat.boundedActiveSessionTranscript(
            messages,
            maximumBytes: maximumBytes
        )

        #expect(bounded.count == 1)
        #expect(bounded.first?.role == .system)
        #expect(bounded.first?.attachments.isEmpty == true)
        #expect(
            TerminalChat.transcriptRetainedByteCount(bounded) <= maximumBytes
        )
    }

    @Test
    func reboundingDoesNotStackTruncationNotices() {
        let messages = (0..<30).map { index in
            AgentRuntimeMessage(
                role: .assistant,
                content: "block-\(index)-" + String(repeating: "z", count: 300)
            )
        }
        let first = TerminalChat.boundedActiveSessionTranscript(
            messages,
            maximumBytes: 3_000
        )
        let second = TerminalChat.boundedActiveSessionTranscript(
            first + messages,
            maximumBytes: 3_000
        )

        #expect(
            second.filter {
                $0.role == .system && $0.content.contains("transcript omitted")
            }.count == 1
        )
        #expect(TerminalChat.transcriptRetainedByteCount(second) <= 3_000)
    }
}
