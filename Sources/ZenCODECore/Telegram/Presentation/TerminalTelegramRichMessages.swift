//
//  TerminalTelegramRichMessages.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Bot API 10.3 adapter. All Telegram-specific discriminator strings and wire
/// shapes remain on this side of the presentation boundary.
enum TerminalTelegramRichMessageRenderer {
    static let maximumBlocks = 100

    static func render(_ document: PresentationDocument) throws -> TerminalTelegramInputRichMessage {
        var blocks: [TerminalTelegramInputRichBlock] = []
        for block in document.blocks.prefix(maximumBlocks) {
            if let rendered = render(block) { blocks.append(rendered) }
        }
        guard !blocks.isEmpty else { throw TerminalTelegramControlError.emptyMessage }
        return TerminalTelegramInputRichMessage(blocks: blocks)
    }

    private static func render(_ block: PresentationBlock) -> TerminalTelegramInputRichBlock? {
        switch block {
        case let .paragraph(text):
            return text.plainText.nilIfBlank.map { _ in .paragraph(richText(text)) }
        case let .heading(level, text):
            return text.plainText.nilIfBlank.map { _ in .heading(size: min(max(level, 1), 6), text: richText(text)) }
        case let .preformatted(code, language):
            guard let code = PresentationSanitizer.visibleText(code).nilIfBlank else { return nil }
            return .preformatted(text: .string(code), language: sanitizedLanguage(language))
        case let .list(ordered, items):
            let renderedItems = items.compactMap { item -> TerminalTelegramInputRichBlockListItem? in
                let rendered = item.compactMap(render)
                return rendered.isEmpty ? nil : .init(blocks: rendered)
            }
            guard !renderedItems.isEmpty else { return nil }
            return .list(ordered: ordered, items: renderedItems)
        }
    }

    private static func richText(_ text: PresentationText) -> TerminalTelegramRichText {
        let values = text.runs.compactMap(renderRun)
        if values.count == 1 { return values[0] }
        return .array(values)
    }

    private static func renderRun(_ run: PresentationTextRun) -> TerminalTelegramRichText? {
        switch run {
        case let .plain(text):
            let sanitized = PresentationSanitizer.visibleText(text)
            return sanitized.isEmpty ? nil : .string(sanitized)
        case let .code(text): return .styled(type: "code", text: .string(PresentationSanitizer.visibleText(text)), url: nil)
        case let .emphasis(text): return .styled(type: "italic", text: richText(text), url: nil)
        case let .strong(text): return .styled(type: "bold", text: richText(text), url: nil)
        case let .link(label, url):
            guard allowedURL(url) else { return .string(label.plainText) }
            return .styled(type: "url", text: richText(label), url: url.absoluteString)
        }
    }

    private static func allowedURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "tg"
    }

    private static func sanitizedLanguage(_ language: String?) -> String? {
        guard let value = language.map(PresentationSanitizer.visibleText)?.nilIfBlank else { return nil }
        let allowed = value.filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-" }
        return String(allowed.prefix(32)).nilIfBlank
    }
}

struct TerminalTelegramInputRichMessage: Encodable, Sendable {
    let blocks: [TerminalTelegramInputRichBlock]
    let isRTL: Bool? = nil
    let skipEntityDetection: Bool? = true

    enum CodingKeys: String, CodingKey {
        case blocks
        case isRTL = "is_rtl"
        case skipEntityDetection = "skip_entity_detection"
    }
}

indirect enum TerminalTelegramRichText: Encodable, Sendable {
    case string(String)
    case array([TerminalTelegramRichText])
    case styled(type: String, text: TerminalTelegramRichText, url: String?)

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .string(value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case let .array(values):
            var container = encoder.unkeyedContainer()
            try container.encode(contentsOf: values)
        case let .styled(type, text, url):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(type, forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(url, forKey: .url)
        }
    }

    private enum CodingKeys: String, CodingKey { case type, text, url }
}

struct TerminalTelegramInputRichBlockListItem: Encodable, Sendable {
    let blocks: [TerminalTelegramInputRichBlock]
    let value: Int?
    let type: String?

    init(blocks: [TerminalTelegramInputRichBlock], value: Int? = nil, type: String? = nil) {
        self.blocks = blocks
        self.value = value
        self.type = type
    }
}

indirect enum TerminalTelegramInputRichBlock: Encodable, Sendable {
    case paragraph(TerminalTelegramRichText)
    case heading(size: Int, text: TerminalTelegramRichText)
    case preformatted(text: TerminalTelegramRichText, language: String?)
    case list(ordered: Bool, items: [TerminalTelegramInputRichBlockListItem])

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .paragraph(text):
            try container.encode("paragraph", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .heading(size, text):
            try container.encode("heading", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encode(size, forKey: .size)
        case let .preformatted(text, language):
            try container.encode("pre", forKey: .type)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(language, forKey: .language)
        case let .list(ordered, items):
            try container.encode("list", forKey: .type)
            let numbered = ordered ? items.enumerated().map {
                TerminalTelegramInputRichBlockListItem(blocks: $0.element.blocks, value: $0.offset + 1, type: "1")
            } : items
            try container.encode(numbered, forKey: .items)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, size, language, items
    }
}

struct TerminalTelegramSendRichMessageRequest: Encodable {
    let chatID: Int64
    let richMessage: TerminalTelegramInputRichMessage
    let replyMarkup: TerminalTelegramReplyMarkup?
    let messageThreadID: Int?

    init(
        chatID: Int64, richMessage: TerminalTelegramInputRichMessage,
        replyMarkup: TerminalTelegramReplyMarkup?, messageThreadID: Int? = nil
    ) {
        self.chatID = chatID
        self.richMessage = richMessage
        self.replyMarkup = replyMarkup
        self.messageThreadID = messageThreadID
    }
}

/// Like ``TerminalTelegramSendMessageDraftRequest``: `messageThreadID` is
/// declared last and omitted when `nil`, so a topic-less draft keeps its wire.
struct TerminalTelegramSendRichMessageDraftRequest: Encodable {
    let chatID: Int64
    let draftID: Int
    let richMessage: TerminalTelegramInputRichMessage
    let canStop: Bool
    let keepOnStop: Bool
    let messageThreadID: Int?
}
