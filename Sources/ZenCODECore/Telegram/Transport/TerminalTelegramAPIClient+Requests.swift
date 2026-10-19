//
//  TerminalTelegramAPIClient+Requests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

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
    let messageThreadID: Int?

    init(
        chatID: Int64, text: String, parseMode: String?,
        replyMarkup: TerminalTelegramReplyMarkup?, messageThreadID: Int? = nil
    ) {
        self.chatID = chatID
        self.text = text
        self.parseMode = parseMode
        self.replyMarkup = replyMarkup
        self.messageThreadID = messageThreadID
    }
}

struct TerminalTelegramSendMessageDraftRequest: Encodable {
    let chatID: Int64
    let draftID: Int
    let text: String
    let canStop: Bool
    let keepOnStop: Bool
    let messageThreadID: Int? = nil
}

struct TerminalTelegramEditMessageTextRequest: Encodable {
    let chatID: Int64
    let messageID: Int
    let text: String
}

struct TerminalTelegramEditMessageReplyMarkupRequest: Encodable {
    let chatID: Int64
    let messageID: Int
    let replyMarkup: TerminalTelegramReplyMarkup?
}

struct TerminalTelegramDeleteMessageRequest: Encodable {
    let chatID: Int64
    let messageID: Int
}

struct TerminalTelegramAnswerCallbackQueryRequest: Encodable {
    let callbackQueryID: String
}

struct TerminalTelegramSetMyCommandsRequest: Encodable {
    let commands: [TerminalTelegramBotCommand]
    let scope: TerminalTelegramBotCommandScope?
    let languageCode: String?
}

/// `BotCommandScope` projection. Only chat-specific scopes carry `chat_id`;
/// all-private-chats and default scopes omit it.
struct TerminalTelegramBotCommandScope: Encodable, Sendable, Equatable {
    let type: String
    let chatID: Int64?

    private enum CodingKeys: String, CodingKey {
        case type
        case chatID = "chat_id"
    }
}

struct TerminalTelegramSendChatActionRequest: Encodable {
    let chatID: Int64
    let action: String
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
    let stoppedMessageGeneration: TerminalTelegramMessageGenerationStopped?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
        case callbackQuery = "callback_query"
        case stoppedMessageGeneration = "stopped_message_generation"
    }
}

extension TerminalTelegramMessage {
    /// The selective media ingress reads at most one document and the largest
    /// photo size; a message that carries other media kinds simply has none.
    var inboundDocument: TerminalTelegramInboundAttachment? {
        document.map { document in
            TerminalTelegramInboundAttachment(
                fileID: document.fileID,
                fileUniqueID: document.fileUniqueID,
                kind: .document,
                mimeType: document.mimeType,
                fileSize: document.fileSize,
                fileName: document.fileName,
                messageID: messageID
            )
        }
    }

    var inboundPhoto: TerminalTelegramInboundAttachment? {
        guard let sizes = photo, let largest = sizes.max(by: { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }) else {
            return nil
        }
        return TerminalTelegramInboundAttachment(
            fileID: largest.fileID,
            fileUniqueID: largest.fileUniqueID,
            kind: .photo,
            mimeType: "image/jpeg",
            fileSize: largest.fileSize,
            fileName: nil,
            messageID: messageID
        )
    }
}

struct TerminalTelegramMessageGenerationStopped: Decodable, Sendable, Equatable {
    let chat: TerminalTelegramChat
    let messageThreadID: Int?
    let draftID: Int

    enum CodingKeys: String, CodingKey {
        case chat
        case messageThreadID = "message_thread_id"
        case draftID = "draft_id"
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
    let messageThreadID: Int?
    let text: String?
    let voice: TerminalTelegramVoice?
    /// Document attachment (Bot API `document`).
    let document: TerminalTelegramDocumentAttachment?
    /// Photo sizes; Telegram sends an array from thumbnail to full size.
    let photo: [TerminalTelegramPhotoSize]?
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
        case messageThreadID = "message_thread_id"
        case text
        case voice
        case document
        case photo
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

/// Bounded projection of a Bot API `document` attachment.
struct TerminalTelegramDocumentAttachment: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let fileName: String?
    let mimeType: String?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case fileName = "file_name"
        case mimeType = "mime_type"
        case fileSize = "file_size"
    }
}

/// Bounded projection of one Bot API photo size.
struct TerminalTelegramPhotoSize: Decodable {
    let fileID: String
    let fileUniqueID: String?
    let width: Int?
    let height: Int?
    let fileSize: Int?

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
        case fileUniqueID = "file_unique_id"
        case width
        case height
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

struct TerminalTelegramChat: Decodable, Sendable, Equatable {
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