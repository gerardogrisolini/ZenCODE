//
//  TerminalTelegramLongResponseTests.swift
//  ZenCODE
//
//  A response longer than one Telegram message: its pages sent as ordered
//  rich messages with the reply markup on the last one, the plain-text
//  fallback of a rejected page and of every later one split and never cut,
//  no fallback nor resend after an ambiguous failure, the cut beyond four
//  messages, the draft that shows the last page, and the reporter bounds of
//  the rich texts against those of the messages edited in place. The wire
//  tests run in a UUID support directory over a scripted Bot API.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(2)))
struct TerminalTelegramLongResponseTests {
    // MARK: - Rich pages

    /// A response beyond one message is sent as ordered rich messages, each
    /// within the budget, every paragraph once and in order; the reply
    /// markup goes only on the last one, whose id is returned.
    @Test
    func aResponseLargerThanOneMessageIsSentAsOrderedRichMessages() async throws {
        let labels = (1 ... 40).map { "Paragraph \($0):" }
        let text = labels.map { "\($0) " + String(repeating: "word ", count: 200) }.joined(separator: "\n\n")
        let transport = PagedWireTransport()
        let messageID = try await Self.send(text, replyMarkup: .forceReply, over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessage", "sendRichMessage"])
        #expect(messageID == requests.last?.messageID)
        #expect(requests.map { $0.object["reply_markup"] != nil } == [false, true])
        for request in requests {
            let cost = Self.wireCost(of: request.blocks)
            #expect(cost.bytes <= 30_000, "\(cost)")
            #expect(cost.blocks <= 450, "\(cost)")
        }
        #expect(Self.labels(in: requests.flatMap(\.paragraphs)) == labels)
    }

    /// A page rejected as incompatible goes out as plain text, and so does
    /// every later page, never as rich again: each page in as many messages
    /// as its text needs, within the limit, nothing cut or repeated, the
    /// reply markup on the last one.
    @Test
    func aCompatibilityRejectionOfTheFirstPageSendsEveryPageAsPlainText() async throws {
        // 450 paragraphs fill the first page; their plain text takes two messages.
        let labels = (1 ... 460).map { String(format: "Paragraph %03d", $0) }
        let transport = PagedWireTransport(richStatuses: [0: 400])
        let messageID = try await Self.send(labels.joined(separator: "\n\n"), replyMarkup: .forceReply, over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessage", "sendMessage", "sendMessage", "sendMessage"])
        let plain = requests.filter { $0.method == "sendMessage" }
        #expect(plain.allSatisfy { ($0.object["text"] as? String)?.utf16.count ?? .max <= 4_000 })
        #expect(plain.allSatisfy { $0.object["parse_mode"] == nil })
        #expect(plain.map { $0.object["reply_markup"] != nil } == [false, false, true])
        #expect(messageID == requests.last?.messageID)
        #expect(Self.labels(in: plain.compactMap { $0.object["text"] as? String }) == labels)
    }

    /// A rejection of a later page: the pages before it stay rich, it and
    /// the rest are plain text, with no other rich call.
    @Test
    func aCompatibilityRejectionOfALaterPageSendsItAndTheRestAsPlainText() async throws {
        let labels = (1 ... 920).map { String(format: "P%04d", $0) }
        let transport = PagedWireTransport(richStatuses: [1: 400])
        _ = try await Self.send(labels.joined(separator: "\n\n"), over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessage", "sendRichMessage", "sendMessage", "sendMessage"])
        let delivered = requests[0].paragraphs + requests.dropFirst(2).compactMap { $0.object["text"] as? String }
        #expect(Self.labels(in: delivered) == labels)
    }

    /// A server error in the middle propagates: no plain-text fallback, no
    /// resend of the page, no later page.
    @Test
    func aServerErrorMidwayFallsBackToNothingAndSendsNothingAgain() async throws {
        let text = (1 ... 920).map { String(format: "P%04d", $0) }.joined(separator: "\n\n")
        let transport = PagedWireTransport(richStatuses: [1: 500])
        await #expect(throws: TerminalTelegramControlError.self) {
            _ = try await Self.send(text, over: transport)
        }
        #expect(transport.requests.map(\.method) == ["sendRichMessage", "sendRichMessage"])
    }

    /// Beyond four messages the response stops at the fourth, which ends
    /// with the truncation notice, here in place of its last paragraph.
    @Test
    func beyondFourMessagesTheLastEndsWithTheTruncationNotice() async throws {
        let labels = (1 ... 2_300).map { String(format: "P%04d", $0) }
        let transport = PagedWireTransport()
        _ = try await Self.send(labels.joined(separator: "\n\n"), over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == Array(repeating: "sendRichMessage", count: 4))
        let last = try #require(requests.last).paragraphs
        #expect(last.last == "… Response truncated.")
        #expect(last.count == 450)
        #expect(Self.labels(in: requests.flatMap(\.paragraphs)) == Array(labels[0 ..< 1_799]))
    }

    // MARK: - Drafts

    /// A draft beyond one message shows its last page, the text being
    /// written.
    @Test
    func aDraftLargerThanOneMessageShowsItsLastPage() async throws {
        let labels = (1 ... 460).map { String(format: "Paragraph %03d", $0) }
        let transport = PagedWireTransport()
        try await Self.sendDraft(labels.joined(separator: "\n\n"), over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessageDraft"])
        #expect(requests.first?.paragraphs == Array(labels[450...]))
    }

    /// On the legacy draft method the draft shows the last plain-text piece
    /// of the page, within the limit.
    @Test
    func aLegacyDraftShowsTheLastPlainPieceWithinTheLimit() async throws {
        let labels = (1 ... 300).map { String(format: "Paragraph %03d", $0) }
        let text = labels.joined(separator: "\n\n")
        let transport = PagedWireTransport(richStatuses: [0: 404])
        try await Self.sendDraft(text, over: transport)

        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendRichMessageDraft", "sendMessageDraft"])
        let draft = try #require(requests.last?.object["text"] as? String)
        #expect(text.utf16.count > 4_000)
        #expect(draft.utf16.count <= 4_000)
        #expect(draft.hasSuffix("Paragraph 300"))
        #expect(!draft.contains("Paragraph 001"))
        #expect(TerminalTelegramAPIClient.messageTextPieces(text).last == draft)
    }

    /// The streamer keeps updating the draft past 4,000 characters, up to
    /// the bound of the response it previews.
    @Test
    func aDraftKeepsUpdatingPastFourThousandCharacters() async throws {
        let drafts = DraftLog()
        let streamer = TerminalTelegramDraftStreamer(chatID: 42, draftID: 7, throttle: .milliseconds(10)) { text, _, _ in
            await drafts.record(text)
        }
        for _ in 0 ..< 5 {
            await streamer.append(String(repeating: "a", count: 1_000))
        }
        #expect(await Self.waitUntil { await drafts.last?.count == 5_000 })

        let limit = TerminalTelegramTurnProgressReporter.maximumRichTextLength
        await streamer.append(String(repeating: "b", count: limit))
        #expect(await Self.waitUntil { await drafts.last?.count == limit })
        #expect(await drafts.last?.hasSuffix("b") == true)
        await streamer.finish()
    }

    // MARK: - Reporter bounds

    /// The text messages of a reporter, which leave as rich messages, arrive
    /// whole beyond 3,900 characters, the response buffer included, up to
    /// their own bound; the sub-agent status, the task-graph card, and the
    /// thinking keep the 3,900-character limit.
    @Test
    func richTextsArriveWholeWhileEditedMessagesKeepTheirLimit() async {
        let log = TelegramTurnActivityWireLog()
        let reporter = log.makeReporter()
        let long = String(repeating: "x", count: 6_000)

        for _ in 0 ..< 10 {
            await reporter.appendAgentResponseDelta(String(repeating: "a", count: 1_000))
        }
        await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.enqueue(.agentResponse(long))
        await reporter.enqueue(.subAgentResponse(long))
        _ = await reporter.send(.authorization(long))
        await reporter.enqueue(.summary(long))
        await reporter.enqueue(.subAgentStatus(long))
        await reporter.enqueue(.tasks(long))
        await reporter.enqueue(.thought(long))
        await reporter.flush()

        let limit = TerminalTelegramTurnProgressReporter.maximumMessageLength
        let effects = await log.effects
        #expect(await log.messages.map(\.count) == [10_000, 6_000, 6_000, 6_000, 6_000])
        #expect(effects.contains(.create(id: 100, text: String(repeating: "x", count: limit))), "\(effects.count)")
        #expect(effects.contains(.cardCreate(id: 101, text: String(repeating: "x", count: limit))))
        let thoughts = effects.compactMap { effect -> String? in
            if case let .thought(text) = effect { return text }
            return nil
        }
        #expect(thoughts.map(\.count) == [limit])

        let bound = TerminalTelegramTurnProgressReporter.maximumRichTextLength
        for _ in 0 ..< 14 {
            await reporter.appendAgentResponseDelta(String(repeating: "c", count: 10_000))
        }
        await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.enqueue(.agentResponse(String(repeating: "d", count: bound + 1)))
        await reporter.flush()
        #expect(await log.messages.suffix(2).map(\.count) == [bound, bound])
        await reporter.retire()
    }

    // MARK: - Helpers

    /// Sends `text` with ``TerminalTelegramControlService/sendRichMessageWithFallback(_:to:topicID:replyMarkup:fence:)``
    /// on a service over `transport`, and returns the message id.
    private static func send(
        _ text: String, replyMarkup: TerminalTelegramReplyMarkup? = nil, over transport: PagedWireTransport
    ) async throws -> Int {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        return try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let epoch = try #require(try await service.start().wireLifecycleEpoch)
            do {
                let messageID = try await service.sendRichMessageWithFallback(
                    text, to: 42, topicID: nil, replyMarkup: replyMarkup, fence: makeFence(epoch: epoch)
                )
                _ = await service.stop()
                return messageID
            } catch {
                _ = await service.stop()
                throw error
            }
        }
    }

    /// Streams `text` as one draft on a service over `transport`.
    private static func sendDraft(_ text: String, over transport: PagedWireTransport) async throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            let service = TerminalTelegramControlService(transportFactory: { transport })
            let epoch = try #require(try await service.start().wireLifecycleEpoch)
            try await service.sendRichMessageDraftWithFallback(text, to: 42, draftID: 5, fence: makeFence(epoch: epoch))
            _ = await service.stop()
        }
    }

    /// The labels (`Paragraph 1:`, `Paragraph 001`, `P0001`) the texts
    /// carry, in order.
    private static func labels(in texts: [String]) -> [String] {
        let pattern = #/Paragraph \d+:|Paragraph \d{3}|P\d{4}/#
        return texts.flatMap { $0.matches(of: pattern).map { String($0.output) } }
    }

    /// The UTF-8 bytes of every text and URL of rendered blocks, and their
    /// blocks with every nested block, list item, and table row counted.
    private static func wireCost(of blocks: [Any]) -> (bytes: Int, blocks: Int) {
        var bytes = 0
        var count = 0
        func visit(_ value: Any, isBlock: Bool) {
            if let string = value as? String {
                bytes += string.utf8.count
            } else if let array = value as? [Any] {
                for element in array { visit(element, isBlock: isBlock) }
            } else if let object = value as? [String: Any] {
                if isBlock { count += 1 }
                for (key, child) in object {
                    switch key {
                    case "text", "url": visit(child, isBlock: false)
                    case "blocks": visit(child, isBlock: true)
                    case "items":
                        for item in child as? [Any] ?? [] {
                            count += 1
                            visit(item, isBlock: false)
                        }
                    case "cells":
                        count += (child as? [Any])?.count ?? 0
                        visit(child, isBlock: false)
                    default: break
                    }
                }
            }
        }
        visit(blocks, isBlock: true)
        return (bytes, count)
    }

    private static func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async -> Bool {
        for _ in 0 ..< 500 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    private static func makeSupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram-long-response-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(
                models: [],
                telegram: AgentTelegramSettingsManifest(
                    enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
                    linkedChatTitle: "Test", ownerUserID: 7,
                    routes: [.init(roomID: "default")]
                )
            ),
            to: url.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        return url
    }

    private static func makeFence(epoch: UUID) -> TerminalTelegramWireFence {
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: "test-room"), generation: 1
        )
        return TerminalTelegramWireFence(lease: lease, lifecycleEpoch: epoch) { candidate in
            guard candidate == lease else { throw CancellationError() }
        }
    }
}

/// The texts the drafts showed, in order.
private actor DraftLog {
    private(set) var texts: [String] = []
    var last: String? { texts.last }
    func record(_ text: String) { texts.append(text) }
}

/// A Bot API fake that answers the lifecycle calls itself, records every
/// other request with the receipt it got (from 100 on), and answers the n-th
/// rich call (`sendRichMessage` or `sendRichMessageDraft`, counted from 0)
/// with the status `richStatuses` gives it, 200 when it gives none.
private final class PagedWireTransport: TelegramHTTPTransport, @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let body: Data
        let messageID: Int

        /// The decoded body.
        var object: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        }

        /// The blocks of a rich message or draft.
        var blocks: [Any] {
            (object["rich_message"] as? [String: Any])?["blocks"] as? [Any] ?? []
        }

        /// The text of every top-level paragraph block, in order.
        var paragraphs: [String] {
            blocks.compactMap { block in
                guard let block = block as? [String: Any], block["type"] as? String == "paragraph" else { return nil }
                return block["text"] as? String
            }
        }
    }

    private struct State {
        var requests: [Request] = []
        var richCalls = 0
        var nextMessageID = 100
    }

    private let state = Mutex(State())
    private let richStatuses: [Int: Int]

    init(richStatuses: [Int: Int] = [:]) {
        self.richStatuses = richStatuses
    }

    var requests: [Request] { state.withLock { $0.requests } }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let apiMethod = url.lastPathComponent
        switch apiMethod {
        case "deleteWebhook", "setMyCommands":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getMe":
            return (200, Data(#"{"ok":true,"result":{"id":9003,"is_bot":true,"first_name":"bot","username":"test_bot"}}"#.utf8))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        default:
            break
        }
        let body = body ?? Data()
        let richStatuses = richStatuses
        let (status, messageID) = state.withLock { state -> (Int, Int) in
            var status = 200
            if apiMethod.hasPrefix("sendRichMessage") {
                status = richStatuses[state.richCalls] ?? 200
                state.richCalls += 1
            }
            let messageID = state.nextMessageID
            state.nextMessageID += 1
            state.requests.append(Request(method: apiMethod, body: body, messageID: status == 200 ? messageID : 0))
            return (status, messageID)
        }
        guard status == 200 else {
            return (status, Data(#"{"ok":false,"error_code":\#(status),"description":"Bad Request: rich messages unsupported"}"#.utf8))
        }
        if apiMethod.hasSuffix("Draft") {
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
        return (200, Data(#"{"ok":true,"result":{"message_id":\#(messageID),"chat":{"id":42,"type":"private"},"date":0}}"#.utf8))
    }
}
