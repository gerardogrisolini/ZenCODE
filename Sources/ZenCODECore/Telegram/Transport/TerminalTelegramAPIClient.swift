//
//  TerminalTelegramAPIClient.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Abstract HTTP transport for the Telegram API client so the concrete
/// transport can be swapped out in tests or replaced with a mock.
protocol TelegramHTTPTransport: Sendable {
    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data)
}

/// Production transport backed by the shared SwiftNIO engine.
struct NIOTelegramHTTPTransport: TelegramHTTPTransport {
    let transport: RemoteTransportCore

    init(transport: RemoteTransportCore = RemoteTransportCore()) {
        self.transport = transport
    }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let request = RemoteHTTPStreamingRequest(
            url: url,
            method: method,
            headers: headers,
            body: body,
            timeout: timeout
        )
        let response = try await transport.sendRequest(request)
        return (response.status, response.body)
    }
}

struct TerminalTelegramAPIClient: Sendable {
    static let maximumAudioFileBytes = 20 * 1_024 * 1_024
    static let audioDownloadTimeout: Duration = .seconds(30)
    /// Telegram rejects a `sendMessage` whose text exceeds 4096 UTF-16 code
    /// units. The budget is kept slightly below that ceiling so a truncation
    /// marker still fits inside the wire limit.
    static let maximumMessageUTF16Length = 4_000
    /// Timeout for multipart uploads (bounded corpus, slow mobile links).
    static let uploadTimeout: Duration = .seconds(120)
    let token: String
    let transport: any TelegramHTTPTransport
    /// Lifecycle/route check executed immediately before every transport
    /// attempt. Governor sleeps and retry bookkeeping happen before this hook.
    let preflight: @Sendable () async throws -> Void

    init(
        token: String,
        transport: any TelegramHTTPTransport = NIOTelegramHTTPTransport(),
        preflight: @escaping @Sendable () async throws -> Void = {}
    ) {
        self.token = token
        self.transport = transport
        self.preflight = preflight
    }

    func getMe() async throws -> TerminalTelegramUser {
        try await request(method: "getMe", body: TerminalTelegramEmptyRequest())
    }

    func deleteWebhook(dropPendingUpdates: Bool) async throws -> Bool {
        try await request(
            method: "deleteWebhook",
            body: TerminalTelegramDeleteWebhookRequest(dropPendingUpdates: dropPendingUpdates)
        )
    }

    func getUpdates(offset: Int?, timeout: Int) async throws -> [TerminalTelegramUpdate] {
        try await request(
            method: "getUpdates",
            body: TerminalTelegramGetUpdatesRequest(
                offset: offset,
                timeout: timeout,
                allowedUpdates: ["message", "callback_query", "stopped_message_generation"]
            )
        )
    }

    /// Sends a message and returns the Telegram `message_id` of the delivered
    /// message. The receipt is what lets a later `reply_to_message` be resolved
    /// back to the shared-chat sender it was produced from; callers that do not
    /// need it can keep ignoring the result.
    ///
    /// Rate limiting and retries are governed by `governor`: the send waits for
    /// any per-chat/global delay (cancellably), records the admission, and is
    /// retried only when Telegram answers with an explicit 429 carrying a
    /// `retry_after`. Every other failure is thrown to the caller untouched,
    /// because an ambiguous outcome must never be retried into a possible
    /// duplicate.
    @discardableResult
    func sendMessage(
        _ text: String,
        to chatID: Int64,
        messageThreadID: Int? = nil,
        parseMode: String? = nil,
        replyMarkup: TerminalTelegramReplyMarkup? = nil,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws -> Int {
        let request = TerminalTelegramSendMessageRequest(
            chatID: chatID,
            text: Self.boundedMessageText(text),
            parseMode: parseMode,
            replyMarkup: replyMarkup,
            messageThreadID: messageThreadID
        )
        let send: () async throws -> Int = {
            let message: TerminalTelegramMessage = try await self.request(
                method: "sendMessage",
                body: request
            )
            return message.messageID
        }
        return try await governed(chatID: chatID, governor: governor, operation: send)
    }

    /// Sends a backend-neutral presentation document using the Bot API 10.3
    /// Rich Messages wire format. Rendering happens before governor admission,
    /// so an invalid local tree never consumes rate budget or touches the wire.
    @discardableResult
    func sendRichMessage(
        _ document: PresentationDocument,
        to chatID: Int64,
        messageThreadID: Int? = nil,
        replyMarkup: TerminalTelegramReplyMarkup? = nil,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws -> Int {
        let richMessage = try TerminalTelegramRichMessageRenderer.render(document)
        let body = TerminalTelegramSendRichMessageRequest(
            chatID: chatID,
            richMessage: richMessage,
            replyMarkup: replyMarkup,
            messageThreadID: messageThreadID
        )
        let send: () async throws -> Int = {
            let message: TerminalTelegramMessage = try await self.request(
                method: "sendRichMessage", body: body
            )
            return message.messageID
        }
        return try await governed(chatID: chatID, governor: governor, operation: send)
    }

    /// Sends a document as `multipart/form-data`.
    ///
    /// The artifact must already have passed the outbound policy: this method
    /// encodes the (bounded) multipart form and posts it. The corpus is read
    /// from disk in bounded chunks by the encoder; the assembled body is one
    /// buffer whose size was pre-checked against the form budget, so the
    /// upload can never exceed Telegram's multipart ceiling or spill an
    /// unbounded file into memory. Sends are governed like every other
    /// outbound call and are retried only on an explicit 429.
    @discardableResult
    func sendDocument(
        _ artifact: TerminalTelegramArtifact,
        to chatID: Int64,
        messageThreadID: Int? = nil,
        caption: String? = nil,
        expectedSHA256: String? = nil,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws -> Int {
        let attributes = try artifact.fileURL.resourceValues(forKeys: [.fileSizeKey])
        let fileSize = attributes.fileSize ?? 0
        var parts: [TerminalTelegramMultipartForm.Part] = [
            .value(name: "chat_id", value: String(chatID)),
            .value(name: "caption", value: caption ?? ""),
            .file(
                name: "document",
                filename: artifact.filename,
                contentType: artifact.contentType ?? "application/octet-stream",
                fileURL: artifact.fileURL,
                fileSize: fileSize
            ),
        ]
        if let messageThreadID {
            parts.insert(.value(name: "message_thread_id", value: String(messageThreadID)), at: 1)
        }
        let form = try TerminalTelegramMultipartForm.form(parts: parts)
        // The hash is computed while materializing the exact multipart bytes.
        // A file replaced after consent can therefore never reach the wire.
        let body = try form.encode(expectedFileSHA256: expectedSHA256)
        let send: () async throws -> Int = {
            let message: TerminalTelegramMessage = try await self.multipartRequest(
                method: "sendDocument",
                body: body,
                contentType: form.contentTypeHeader
            )
            return message.messageID
        }
        return try await governed(chatID: chatID, governor: governor, operation: send)
    }

    func answerCallbackQuery(_ callbackQueryID: String) async throws {
        let _: Bool = try await request(
            method: "answerCallbackQuery",
            body: TerminalTelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID)
        )
    }

    /// Streams an ephemeral, plain-text preview. Persistence is deliberately
    /// left to `sendMessage`; callers can therefore disable drafts after any
    /// failure without risking duplicate final messages.
    func sendMessageDraft(
        _ text: String,
        to chatID: Int64,
        draftID: Int,
        canStop: Bool = true,
        keepOnStop: Bool = true,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws {
        precondition(draftID != 0)
        let body = TerminalTelegramSendMessageDraftRequest(
            chatID: chatID,
            draftID: draftID,
            text: Self.boundedMessageText(text),
            canStop: canStop,
            keepOnStop: keepOnStop
        )
        try await governed(chatID: chatID, governor: governor) {
            let _: Bool = try await request(method: "sendMessageDraft", body: body)
        }
    }

    /// Streams an ephemeral Bot API 10.3 rich draft. Like plain drafts, callers
    /// must persist the completed response separately.
    func sendRichMessageDraft(
        _ document: PresentationDocument,
        to chatID: Int64,
        draftID: Int,
        canStop: Bool = true,
        keepOnStop: Bool = true,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws {
        precondition(draftID != 0)
        let richMessage = try TerminalTelegramRichMessageRenderer.render(document)
        let body = TerminalTelegramSendRichMessageDraftRequest(
            chatID: chatID,
            draftID: draftID,
            richMessage: richMessage,
            canStop: canStop,
            keepOnStop: keepOnStop
        )
        try await governed(chatID: chatID, governor: governor) {
            let _: Bool = try await request(method: "sendRichMessageDraft", body: body)
        }
    }

    func editMessageText(
        _ text: String,
        chatID: Int64,
        messageID: Int,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws {
        try await governed(chatID: chatID, governor: governor) {
            let _: TerminalTelegramMessage = try await request(
                method: "editMessageText",
                body: TerminalTelegramEditMessageTextRequest(
                    chatID: chatID,
                    messageID: messageID,
                    text: Self.boundedMessageText(text)
                )
            )
        }
    }

    func editMessageReplyMarkup(
        _ replyMarkup: TerminalTelegramReplyMarkup?,
        chatID: Int64,
        messageID: Int,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws {
        try await governed(chatID: chatID, governor: governor) {
            let _: TerminalTelegramMessage = try await request(
                method: "editMessageReplyMarkup",
                body: TerminalTelegramEditMessageReplyMarkupRequest(
                    chatID: chatID,
                    messageID: messageID,
                    replyMarkup: replyMarkup
                )
            )
        }
    }

    func deleteMessage(
        chatID: Int64,
        messageID: Int,
        governor: TerminalTelegramRateGovernor? = nil
    ) async throws {
        try await governed(chatID: chatID, governor: governor) {
            let _: Bool = try await request(
                method: "deleteMessage",
                body: TerminalTelegramDeleteMessageRequest(chatID: chatID, messageID: messageID)
            )
        }
    }

    private func governed<T>(
        chatID: Int64,
        governor: TerminalTelegramRateGovernor?,
        operation: () async throws -> T
    ) async throws -> T {
        guard let governor else { return try await operation() }
        var retryCount = 0
        while true {
            if let delay = await governor.reserve(chatID: chatID) {
                try await Task.sleep(for: delay.duration)
                continue
            }
            do {
                return try await operation()
            } catch let error as TerminalTelegramControlError {
                guard error.isExplicitRateLimit,
                      await governor.retryAfterFailure(error, chatID: chatID),
                      retryCount < TerminalTelegramRateGovernor.maximumRetryCount else { throw error }
                retryCount += 1
            }
        }
    }

    /// Publishes the command menu for the private-chat scope. Returns the
    /// boolean the Bot API replies with.
    @discardableResult
    func setMyCommands(
        _ commands: [TerminalTelegramBotCommand],
        languageCode: String? = nil
    ) async throws -> Bool {
        let _: Bool = try await request(
            method: "setMyCommands",
            body: TerminalTelegramSetMyCommandsRequest(
                commands: commands,
                scope: TerminalTelegramBotCommandScope(type: "all_private_chats", chatID: nil),
                languageCode: languageCode
            )
        )
        return true
    }

    /// Fires a typing indicator. Presence uses a best-effort path: a failed
    /// chat action says nothing about the link or the bot token, so errors are
    /// surfaced only through the caller's diagnostics, never thrown into a
    /// turn.
    func sendChatAction(action: String = "typing", to chatID: Int64) async throws {
        let _: Bool = try await request(
            method: "sendChatAction",
            body: TerminalTelegramSendChatActionRequest(chatID: chatID, action: action)
        )
    }

    /// Trims and bounds one outbound message to the Telegram wire limit.
    ///
    /// The limit Telegram enforces counts UTF-16 code units, not Swift
    /// `Character`s: a text made of emoji or other non-BMP scalars can be well
    /// below 4000 grapheme clusters and still be rejected on the wire. The bound
    /// is therefore measured in UTF-16 units, while truncation still happens on
    /// grapheme-cluster boundaries so a cut can never split a combining sequence
    /// or an emoji into unpaired surrogates.
    static func boundedMessageText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf16.count > maximumMessageUTF16Length else {
            return trimmed
        }
        var bounded = ""
        var length = 0
        for character in trimmed {
            let width = character.utf16.count
            guard length + width <= maximumMessageUTF16Length else { break }
            bounded.append(character)
            length += width
        }
        // A single extended grapheme can itself exceed the wire budget. It
        // cannot be split safely, so send a small visible replacement instead
        // of the empty payload rejected by Telegram.
        return bounded.isEmpty ? "…" : bounded
    }

    func downloadFile(
        fileID: String,
        validateBeforeDownload: @Sendable () async throws -> Void = {}
    ) async throws -> TerminalTelegramDownloadedFile {
        let file: TerminalTelegramFile = try await request(
            method: "getFile",
            body: TerminalTelegramGetFileRequest(fileID: fileID)
        )
        if let fileSize = file.fileSize, fileSize > Self.maximumAudioFileBytes {
            throw TerminalTelegramControlError.fileTooLarge(limit: Self.maximumAudioFileBytes)
        }
        guard let filePath = file.filePath?.nilIfBlank,
              let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else {
            throw TerminalTelegramControlError.unexpectedResponse
        }
        // `getFile` is a separate wire round-trip. Lifecycle owners get a fence
        // here so a stop that occurred while it was suspended prevents the
        // subsequent file GET entirely.
        try await validateBeforeDownload()

        try await preflight()
        let response = try await transport.send(
            url: url,
            method: "GET",
            headers: [],
            body: nil,
            timeout: Self.audioDownloadTimeout
        )
        guard (200..<300).contains(response.status) else {
            throw TerminalTelegramControlError.unexpectedResponse
        }
        guard response.body.count <= Self.maximumAudioFileBytes else {
            throw TerminalTelegramControlError.fileTooLarge(limit: Self.maximumAudioFileBytes)
        }
        return TerminalTelegramDownloadedFile(
            data: response.body,
            filename: URL(fileURLWithPath: filePath).lastPathComponent.nilIfBlank
                ?? "telegram-voice.oga"
        )
    }

    private func multipartRequest(
        method: String,
        body: Data,
        contentType: String
    ) async throws -> TerminalTelegramMessage {
        try await post(method: method, body: body, contentType: contentType, timeout: Self.uploadTimeout)
    }

    func request<Request: Encodable, Response: Decodable>(
        method: String,
        body: Request
    ) async throws -> Response {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try await post(
            method: method,
            body: try encoder.encode(body),
            contentType: "application/json",
            timeout: .seconds(35)
        )
    }

    /// POSTs a pre-encoded body and decodes the standard Bot API envelope.
    private func post<Response: Decodable>(
        method: String,
        body: Data,
        contentType: String,
        timeout: Duration
    ) async throws -> Response {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TerminalTelegramControlError.invalidToken
        }
        try await preflight()
        let response = try await transport.send(
            url: url,
            method: "POST",
            headers: [RemoteHTTPHeader(name: "Content-Type", value: contentType)],
            body: body,
            timeout: timeout
        )
        let decoded: TerminalTelegramAPIResponse<Response>
        do {
            decoded = try JSONDecoder().decode(
                TerminalTelegramAPIResponse<Response>.self,
                from: response.body
            )
        } catch {
            guard (200..<300).contains(response.status) else {
                throw TerminalTelegramControlError.httpError(
                    response.status,
                    String(validating: response.body, as: UTF8.self)
                )
            }
            throw TerminalTelegramControlError.unexpectedResponse
        }
        guard (200..<300).contains(response.status),
              decoded.ok,
              let result = decoded.result else {
            throw TerminalTelegramControlError.apiFailure(
                status: response.status,
                errorCode: decoded.errorCode,
                description: decoded.description,
                retryAfter: decoded.parameters?.retryAfter
            )
        }
        return result
    }
}
