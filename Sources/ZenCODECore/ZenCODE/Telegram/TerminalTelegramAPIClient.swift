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
                allowedUpdates: ["message"]
            )
        )
    }

    func sendMessage(
        _ text: String,
        to chatID: Int64,
        parseMode: String? = nil
    ) async throws {
        let request = TerminalTelegramSendMessageRequest(
            chatID: chatID,
            text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(4_000)),
            parseMode: parseMode
        )
        let _: TerminalTelegramMessage = try await self.request(
            method: "sendMessage",
            body: request
        )
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

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case updateID = "update_id"
        case message
    }
}

struct TerminalTelegramMessage: Decodable {
    let messageID: Int
    let from: TerminalTelegramUser?
    let chat: TerminalTelegramChat
    let text: String?
    let voice: TerminalTelegramVoice?

    // Responses decode with the default strategy, so wire keys stay manual.
    enum CodingKeys: String, CodingKey {
        case messageID = "message_id"
        case from
        case chat
        case text
        case voice
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