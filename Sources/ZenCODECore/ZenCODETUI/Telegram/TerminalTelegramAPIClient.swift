//
//  TerminalTelegramAPIClient.swift
//  ZenCODE
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct TerminalTelegramAPIClient: Sendable {
    let token: String

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

    func sendAudio(
        _ audio: AgentVoiceSynthesisOutput,
        to chatID: Int64
    ) async throws {
        guard let url = URL(string: "https://api.telegram.org/bot\(token)/sendAudio") else {
            throw TerminalTelegramControlError.invalidToken
        }
        let audioData = try Data(contentsOf: audio.fileURL)
        let boundary = "ZenCODE-\(UUID().uuidString)"
        var body = Data()
        body.appendTelegramMultipartField(
            name: "chat_id",
            value: String(chatID),
            boundary: boundary
        )
        body.appendTelegramMultipartFile(
            name: "audio",
            filename: audio.filename,
            contentType: audio.contentType,
            data: audioData,
            boundary: boundary
        )
        body.appendString("--\(boundary)--\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

        let decoded = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<TerminalTelegramMessage>.self,
            from: data
        )
        guard (200..<300).contains(httpResponse.statusCode),
              decoded.ok,
              decoded.result != nil else {
            throw TerminalTelegramControlError.httpError(
                httpResponse.statusCode,
                decoded.description ?? String(data: data, encoding: .utf8)
            )
        }
    }

    func downloadFile(fileID: String) async throws -> TerminalTelegramDownloadedFile {
        let file: TerminalTelegramFile = try await request(
            method: "getFile",
            body: TerminalTelegramGetFileRequest(fileID: fileID)
        )
        guard let filePath = file.filePath?.nilIfBlank,
              let url = URL(string: "https://api.telegram.org/file/bot\(token)/\(filePath)") else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw TerminalTelegramControlError.unexpectedResponse
        }
        return TerminalTelegramDownloadedFile(
            data: data,
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

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 35
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TerminalTelegramControlError.unexpectedResponse
        }

        let decoded = try JSONDecoder().decode(
            TerminalTelegramAPIResponse<Response>.self,
            from: data
        )
        guard (200..<300).contains(httpResponse.statusCode),
              decoded.ok,
              let result = decoded.result else {
            throw TerminalTelegramControlError.httpError(
                httpResponse.statusCode,
                decoded.description ?? String(data: data, encoding: .utf8)
            )
        }
        return result
    }
}

extension Data {
    mutating func appendTelegramMultipartField(
        name: String,
        value: String,
        boundary: String
    ) {
        appendString("--\(boundary)\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\n\n")
        appendString("\(value)\n")
    }

    mutating func appendTelegramMultipartFile(
        name: String,
        filename: String,
        contentType: String,
        data: Data,
        boundary: String
    ) {
        appendString("--\(boundary)\n")
        appendString(
                        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\n"
        )
        appendString("Content-Type: \(contentType)\n\n")
        append(data)
        appendString("\n")
    }

    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}

public enum TerminalTelegramControlError: LocalizedError, Sendable, Equatable {
    case missingConfiguration
    case invalidToken
    case emptyMessage
    case missingAudioFile(String)
    case unexpectedResponse
    case httpError(Int, String?)

    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Telegram is not configured. Run zen --setup and enable Telegram remote control."
        case .invalidToken:
            return "Telegram bot token is invalid."
        case .emptyMessage:
            return "Cannot send an empty Telegram message."
        case let .missingAudioFile(path):
            return "Telegram audio file does not exist: \(path)"
        case .unexpectedResponse:
            return "Telegram returned an unexpected response."
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

    enum CodingKeys: String, CodingKey {
        case dropPendingUpdates = "drop_pending_updates"
    }
}

struct TerminalTelegramGetUpdatesRequest: Encodable {
    let offset: Int?
    let timeout: Int
    let allowedUpdates: [String]

    enum CodingKeys: String, CodingKey {
        case offset
        case timeout
        case allowedUpdates = "allowed_updates"
    }
}

struct TerminalTelegramSendMessageRequest: Encodable {
    let chatID: Int64
    let text: String
    let parseMode: String?

    enum CodingKeys: String, CodingKey {
        case chatID = "chat_id"
        case text
        case parseMode = "parse_mode"
    }
}

struct TerminalTelegramGetFileRequest: Encodable {
    let fileID: String

    enum CodingKeys: String, CodingKey {
        case fileID = "file_id"
    }
}

struct TerminalTelegramDownloadedFile: Sendable {
    let data: Data
    let filename: String
}

struct TerminalTelegramUpdate: Decodable {
    let updateID: Int
    let message: TerminalTelegramMessage?

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
