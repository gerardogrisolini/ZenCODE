//
//  TerminalTelegramAPIClient.swift
//  ZenCODE
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
    let token: String
    let transport: any TelegramHTTPTransport

    init(token: String, transport: any TelegramHTTPTransport = NIOTelegramHTTPTransport()) {
        self.token = token
        self.transport = transport
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

    func getUpdates(
        offset: Int?,
        timeout: Int
    ) async throws -> [TerminalTelegramUpdate] {
        try await request(
            method: "getUpdates",
            body: TerminalTelegramGetUpdatesRequest(
                offset: offset,
                timeout: timeout,
                allowedUpdates: ["message", "callback_query"]
            )
        )
    }

    /// Sends a message and returns the Telegram `message_id` of the delivered
    /// message. The receipt is what lets a later `reply_to_message` be resolved
    /// back to the shared-chat sender it was produced from; callers that do not
    /// need it can keep ignoring the result.
    @discardableResult
    func sendMessage(
        _ text: String,
        to chatID: Int64,
        parseMode: String? = nil,
        replyMarkup: TerminalTelegramReplyMarkup? = nil
    ) async throws -> Int {
        let request = TerminalTelegramSendMessageRequest(
            chatID: chatID,
            text: Self.boundedMessageText(text),
            parseMode: parseMode,
            replyMarkup: replyMarkup
        )
        let message: TerminalTelegramMessage = try await self.request(
            method: "sendMessage",
            body: request
        )
        return message.messageID
    }

    func answerCallbackQuery(_ callbackQueryID: String) async throws {
        let _: Bool = try await request(
            method: "answerCallbackQuery",
            body: TerminalTelegramAnswerCallbackQueryRequest(callbackQueryID: callbackQueryID)
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

    func downloadFile(fileID: String) async throws -> TerminalTelegramDownloadedFile {
        let file: TerminalTelegramFile = try await request(
            method: "getFile",
            body: TerminalTelegramGetFileRequest(fileID: fileID)
        )
        if let fileSize = file.fileSize, fileSize > Self.maximumAudioFileBytes {
            throw TerminalTelegramControlError.fileTooLarge(
                limit: Self.maximumAudioFileBytes
            )
        }
        guard let filePath = file.filePath?.nilIfBlank,
              let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

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
            throw TerminalTelegramControlError.fileTooLarge(
                limit: Self.maximumAudioFileBytes
            )
        }
        return TerminalTelegramDownloadedFile(
            data: response.body,
            filename: URL(fileURLWithPath: filePath).lastPathComponent.nilIfBlank
                ?? "telegram-voice.oga"
        )
    }

    func request<Request: Encodable, Response: Decodable>(
        method: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/\(method)") else {
            throw TerminalTelegramControlError.invalidToken
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let bodyData = try encoder.encode(body)
        let response = try await transport.send(
            url: url,
            method: "POST",
            headers: [RemoteHTTPHeader(name: "Content-Type", value: "application/json")],
            body: bodyData,
            timeout: .seconds(35)
        )

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(
            TerminalTelegramAPIResponse<Response>.self,
            from: response.body
        )
        guard (200..<300).contains(response.status),
              decoded.ok,
              let result = decoded.result else {
            throw TerminalTelegramControlError.httpError(
                response.status,
                decoded.description ?? String(validating: response.body, as: UTF8.self)
            )
        }
        return result
    }
}

public enum TerminalTelegramControlError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case invalidToken
    case emptyMessage
    case unexpectedResponse
    case fileTooLarge(limit: Int)
    case httpError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Telegram is not configured. Run the /setup command in zen and enable Telegram remote control."
        case .invalidToken:
            return "Telegram bot token is invalid."
        case .emptyMessage:
            return "Cannot send an empty Telegram message."
        case .unexpectedResponse:
            return "Telegram returned an unexpected response."
        case let .fileTooLarge(limit):
            return "Telegram audio exceeds the \(limit)-byte download limit."
        case let .httpError(statusCode, body):
            let detail = body?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let detail, !detail.isEmpty {
                return "Telegram returned HTTP \(statusCode): \(detail)"
            }
            return "Telegram returned HTTP \(statusCode)."
        }
    }
}

struct TerminalTelegramAPIResponse<Result: Decodable>: Decodable {
    let ok: Bool
    let result: Result?
    let description: String?
}

struct TerminalTelegramEmptyRequest: Encodable {}

struct TerminalTelegramDeleteWebhookRequest: Encodable {
    let dropPendingUpdates: Bool

}

struct TerminalTelegramGetUpdatesRequest: Encodable {
    let offset: Int?
    let timeout: Int
    let allowedUpdates: [String]

}

struct TerminalTelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String
    let parseMode: String?
    let replyMarkup: TerminalTelegramReplyMarkup?
}

struct TerminalTelegramAnswerCallbackQueryRequest: Encodable {
    let callbackQueryID: String
}

/// The two reply-markup forms used by ZenCODE. Callback data contains only a
/// readable mention handle, never a stable participant identifier.
enum TerminalTelegramReplyMarkup: Encodable, Sendable, Equatable {
    case inlineKeyboard([[TerminalTelegramInlineKeyboardButton]])
    case forceReply

    enum CodingKeys: String, CodingKey { case inlineKeyboard, forceReply }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .inlineKeyboard(rows): try container.encode(rows, forKey: .inlineKeyboard)
        case .forceReply: try container.encode(true, forKey: .forceReply)
        }
    }
}

struct TerminalTelegramInlineKeyboardButton: Encodable, Sendable, Equatable {
    let text: String
    let callbackData: String
}

struct TerminalTelegramGetFileRequest: Encodable {
    let fileID: String

}

struct TerminalTelegramDownloadedFile: Sendable {
    let data: Data
    let filename: String
}

struct TerminalTelegramUpdate: Decodable {
    let updateID: Int
    let message: TerminalTelegramMessage?
    let callbackQuery: TerminalTelegramCallbackQuery?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
    }
}

/// Bounded projection of a callback query. Only callback id, sender, opaque
/// data and the originating message are needed; no user-controlled nested data
/// is decoded.
struct TerminalTelegramCallbackQuery: Decodable {
    let id: String
    let from: TerminalTelegramUser
    let data: String?
    let message: TerminalTelegramMessage?
}

struct TerminalTelegramMessage: Decodable {
    let messageID: Int
    let from: TerminalTelegramUser?
    let chat: TerminalTelegramChat
    let text: String?
    let voice: TerminalTelegramVoice?
    /// Present when the user used Telegram's *Reply* action. Only the referenced
    /// identifier is decoded: `reply_to_message` is a full `Message` on the wire
    /// and decoding it recursively would be unbounded work driven by remote
    /// input for a value nothing else reads.
    let replyToMessage: TerminalTelegramReferencedMessage?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
        case voice
        case replyToMessage = "reply_to_message"
    }
}

/// Non-recursive projection of a referenced Telegram message.
struct TerminalTelegramReferencedMessage: Decodable {
    let messageID: Int

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
    }
}

struct TerminalTelegramVoice: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let duration: Int?
    let mimeType: String?
    let fileSize: Int?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case duration
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

struct TerminalTelegramFile: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let fileSize: Int?
    let filePath: String?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileSize = "file_size"
        case filePath = "file_path"
    }
}

struct TerminalTelegramUser: Decodable {
    let id: Int64
    let isBot: Bool?
    let username: String?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case id
        case isBot = "is_bot"
        case username
    }
}

struct TerminalTelegramChat: Decodable {
    let id: Int64
    let type: String
    let title: String?
    let username: String?
    let firstName: String?
    let lastName: String?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case username
        case firstName = "first_name"
        case lastName = "last_name"
    }

    var displayTitle: String? {
        title
            ?? username.map { "@\($0)" }
            ?? [firstName, lastName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank }
                .joined(separator: " ")
                .nilIfBlank
    }
}