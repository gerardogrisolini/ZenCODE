import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct TerminalTelegramStreamingTests {
    actor DraftRecorder {
        var values: [(String, Int64, Int)] = []
        var attempts = 0
        let fails: Bool
        init(fails: Bool = false) { self.fails = fails }
        func send(_ text: String, _ chatID: Int64, _ draftID: Int) throws {
            attempts += 1
            if fails { throw URLError(.networkConnectionLost) }
            values.append((text, chatID, draftID))
        }
    }

    @Test
    func draftCoalescesRapidDeltasAndUsesStableIdentity() async throws {
        let recorder = DraftRecorder()
        let streamer = TerminalTelegramDraftStreamer(
            chatID: 42, draftID: 77, throttle: .milliseconds(25)
        ) { text, chatID, draftID in
            try await recorder.send(text, chatID, draftID)
        }
        await streamer.append("hel")
        await streamer.append("lo")
        for _ in 0..<200 where await recorder.values.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let values = await recorder.values
        #expect(values.count == 1)
        #expect(values.first?.0 == "hello")
        #expect(values.first?.1 == 42)
        #expect(values.first?.2 == 77)
        #expect(await streamer.owns(chatID: 42, draftID: 77))
    }

    @Test
    func finishingBeforeThrottlePreventsLateDraft() async throws {
        let recorder = DraftRecorder()
        let streamer = TerminalTelegramDraftStreamer(
            chatID: 1, draftID: 2, throttle: .milliseconds(80)
        ) { text, chatID, draftID in
            try await recorder.send(text, chatID, draftID)
        }
        await streamer.append("partial")
        await streamer.finish()
        try await Task.sleep(for: .milliseconds(120))
        #expect(await recorder.values.isEmpty)
        #expect(!(await streamer.owns(chatID: 1, draftID: 2)))
    }

    @Test
    func failedDraftDisablesStreamWithoutFallbackDuplicate() async throws {
        let recorder = DraftRecorder(fails: true)
        let streamer = TerminalTelegramDraftStreamer(
            chatID: 1, draftID: 9, throttle: .milliseconds(10)
        ) { text, chatID, draftID in
            try await recorder.send(text, chatID, draftID)
        }
        await streamer.append("a")
        try await Task.sleep(for: .milliseconds(40))
        await streamer.append("b")
        try await Task.sleep(for: .milliseconds(40))
        #expect(await recorder.attempts == 1)
        #expect(await recorder.values.isEmpty)
    }

    @Test
    func failedDraftStillPersistsExactlyOneFinalMessage() async throws {
        let drafts = DraftRecorder(fails: true)
        let finals = CardRecorder()
        let reporter = TerminalTelegramTurnProgressReporter(
            chatID: 42,
            sendMessage: { text, chat in
                _ = await finals.send(text, chat)
                return true
            },
            sendDraft: { text, chat, id in try await drafts.send(text, chat, id) }
        )
        await reporter.appendAgentResponseDelta("complete answer")
        for _ in 0..<300 where await drafts.attempts == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.flush()
        #expect(await drafts.attempts == 1)
        #expect(await finals.sends == ["complete answer"])
        await reporter.retire()
    }

    actor CardRecorder {
        var nextID = 10
        var sends: [String] = []
        var edits: [(String, Int64, Int)] = []
        var markups: [(Int64, Int, TerminalTelegramReplyMarkup?)] = []
        var deletes: [(Int64, Int)] = []
        func send(_ text: String, _: Int64) -> Int { sends.append(text); defer { nextID += 1 }; return nextID }
        func edit(_ text: String, _ chat: Int64, _ id: Int) { edits.append((text, chat, id)) }
        func markup(_ value: TerminalTelegramReplyMarkup?, _ chat: Int64, _ id: Int) { markups.append((chat, id, value)) }
        func delete(_ chat: Int64, _ id: Int) { deletes.append((chat, id)) }
    }

    @Test
    func ambiguousInitialCardDeliveryDisablesFurtherCreates() async {
        actor Attempts {
            var count = 0
            func fail() throws -> Int {
                count += 1
                throw URLError(.networkConnectionLost)
            }
        }
        let attempts = Attempts()
        let ledger = TerminalTelegramProgressCardLedger(
            chatID: 42,
            send: { _, _ in try await attempts.fail() },
            editText: { _, _, _ in }, editMarkup: { _, _, _ in }, delete: { _, _ in }
        )
        await ledger.update(text: "first")
        await ledger.update(text: "second")
        #expect(await attempts.count == 1)
        #expect(await ledger.currentOwnership() == nil)
    }

    actor SendGate {
        private var startedContinuation: CheckedContinuation<Void, Never>?
        private var releaseContinuation: CheckedContinuation<Int, Never>?
        private var didStart = false
        func send() async -> Int {
            didStart = true
            startedContinuation?.resume()
            startedContinuation = nil
            return await withCheckedContinuation { releaseContinuation = $0 }
        }
        func waitUntilStarted() async {
            if didStart { return }
            await withCheckedContinuation { startedContinuation = $0 }
        }
        func release(id: Int) { releaseContinuation?.resume(returning: id); releaseContinuation = nil }
    }

    @Test
    func progressCardEditsOnlyItsOwnedReceiptAndDeletesOnRetire() async {
        let recorder = CardRecorder()
        let ledger = TerminalTelegramProgressCardLedger(
            chatID: 42,
            send: { text, chat in await recorder.send(text, chat) },
            editText: { text, chat, id in await recorder.edit(text, chat, id) },
            editMarkup: { markup, chat, id in await recorder.markup(markup, chat, id) },
            delete: { chat, id in await recorder.delete(chat, id) }
        )
        await ledger.update(text: "Task 1")
        await ledger.update(text: "Task 2")
        let owned = await ledger.currentOwnership()
        #expect(owned == .init(chatID: 42, messageID: 10, generation: 0))
        #expect(await recorder.sends == ["Task 1"])
        #expect(await recorder.edits.map(\.0) == ["Task 2"])
        await ledger.retire(deleteMessage: true)
        #expect(await recorder.deletes.count == 1)
        #expect(await ledger.currentOwnership() == nil)
    }

    @Test
    func progressCardReceiptArrivingAfterRetireIsDeletedNotAdopted() async {
        let recorder = CardRecorder()
        let gate = SendGate()
        let ledger = TerminalTelegramProgressCardLedger(
            chatID: 42,
            send: { _, _ in await gate.send() },
            editText: { _, _, _ in },
            editMarkup: { _, _, _ in },
            delete: { chat, id in await recorder.delete(chat, id) }
        )
        let update = Task { await ledger.update(text: "pending") }
        await gate.waitUntilStarted()
        await ledger.retire(deleteMessage: true)
        await gate.release(id: 55)
        await update.value
        #expect(await ledger.currentOwnership() == nil)
        let deleted = await recorder.deletes
        #expect(deleted.count == 1)
        #expect(deleted.first?.0 == 42)
        #expect(deleted.first?.1 == 55)
    }

    @Test
    func stoppedDraftOwnershipIsFencedAtBoundary() async {
        let reporter = TerminalTelegramTurnProgressReporter(
            chatID: 42,
            sendMessage: { _, _ in true },
            sendDraft: { _, _, _ in }
        )
        let firstID = await reporter.draftStreamerIDForTesting()
        #expect(firstID != nil)
        #expect(await reporter.ownsStoppedDraft(chatID: 42, draftID: firstID!))
        await reporter.appendAgentResponseDelta("done")
        _ = await reporter.publishPendingAgentResponseAtBoundary()
        #expect(!(await reporter.ownsStoppedDraft(chatID: 42, draftID: firstID!)))
        await reporter.retire()
    }
}

private final class StreamingWireTransport: TelegramHTTPTransport, @unchecked Sendable {
    struct Request: Sendable { let method: String; let body: Data }
    private let storage = Mutex<[Request]>([])
    func send(url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?) async throws -> (status: Int, body: Data) {
        storage.withLock { $0.append(Request(method: url.lastPathComponent, body: body ?? Data())) }
        if url.lastPathComponent == "deleteMessage" || url.lastPathComponent == "sendMessageDraft" {
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
        return (200, Data(#"{"ok":true,"result":{"message_id":8,"chat":{"id":42,"type":"private"},"text":"ok"}}"#.utf8))
    }
    var requests: [Request] { storage.withLock { $0 } }
}

@Suite
struct TerminalTelegramStreamingWireTests {
    @Test
    func nativeDraftAndOwnedMutationWireShapesArePlainAndBounded() async throws {
        let transport = StreamingWireTransport()
        let client = TerminalTelegramAPIClient(token: "secret", transport: transport)
        try await client.sendMessageDraft("visible", to: 42, draftID: 99)
        try await client.editMessageText("progress", chatID: 42, messageID: 8)
        try await client.editMessageReplyMarkup(nil, chatID: 42, messageID: 8)
        try await client.deleteMessage(chatID: 42, messageID: 8)
        let requests = transport.requests
        #expect(requests.map(\.method) == ["sendMessageDraft", "editMessageText", "editMessageReplyMarkup", "deleteMessage"])
        let draft = try JSONSerialization.jsonObject(with: requests[0].body) as? [String: Any]
        #expect(draft?["chat_id"] as? Int == 42)
        #expect(draft?["draft_id"] as? Int == 99)
        #expect(draft?["text"] as? String == "visible")
        #expect(draft?["can_stop"] as? Bool == true)
        #expect(draft?["keep_on_stop"] as? Bool == true)
        #expect(!String(decoding: requests[0].body, as: UTF8.self).contains("secret"))
    }

    @Test
    func stoppedGenerationUpdateDecodesCorrelationFields() throws {
        let data = Data(#"{"update_id":5,"stopped_message_generation":{"chat":{"id":42,"type":"private"},"draft_id":99}}"#.utf8)
        let update = try JSONDecoder().decode(TerminalTelegramUpdate.self, from: data)
        #expect(update.stoppedMessageGeneration?.chat.id == 42)
        #expect(update.stoppedMessageGeneration?.draftID == 99)
    }
}
