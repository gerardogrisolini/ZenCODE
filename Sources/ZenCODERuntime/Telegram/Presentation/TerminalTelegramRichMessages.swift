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
    /// The budget of one rich message and of one response, the only place
    /// these limits are set. The Bot API accepts at most 32,768 UTF-8
    /// characters of text and 500 blocks (nested blocks, list items, table
    /// rows, and quotation blocks counted) in a rich message: ZenCODE counts
    /// bytes, the cautious reading of the limit, and stays below both. A
    /// response larger than one message is sent as several, split at block
    /// boundaries (``PresentationDocument/pages(within:)``); one that needs
    /// more than `maximumPages` messages is cut, visibly.
    static let messageBudget = PresentationPageBudget(
        maximumTextBytes: 30_000,
        maximumBlocks: 450,
        maximumPages: 4,
        truncationNotice: "… Response truncated."
    )
    /// The Bot API accepts at most 20 columns in a `table` block; a wider
    /// table is sent as a `pre` block with its plain-text projection.
    static let maximumTableColumns = 20
    /// The Bot API accepts at most 16 levels of nested blocks and formatting.
    /// Content that would sit deeper than this level, which keeps a margin, is
    /// flattened into its plain text, so no text is lost.
    static let maximumNestingDepth = 12

    /// Renders every block of `document`: a document larger than one
    /// message is split into pages before (``messageBudget``).
    static func render(_ document: PresentationDocument) throws -> TerminalTelegramInputRichMessage {
        var blocks: [TerminalTelegramInputRichBlock] = []
        for block in document.blocks {
            if let rendered = render(block, depth: 1) { blocks.append(rendered) }
        }
        guard !blocks.isEmpty else { throw TerminalTelegramControlError.emptyMessage }
        return TerminalTelegramInputRichMessage(blocks: blocks)
    }

    /// Renders `block` at nesting level `depth`, 1 for a top-level block. A
    /// list item takes one level below its list and the item's blocks one
    /// more; a quotation's blocks and a table's cells one level below them; a
    /// text style one level below the block or style that holds it.
    private static func render(_ block: PresentationBlock, depth: Int) -> TerminalTelegramInputRichBlock? {
        switch block {
        case let .paragraph(text):
            return text.plainText.nilIfBlank.map { _ in .paragraph(richText(text, depth: depth)) }
        case let .heading(level, text):
            return text.plainText.nilIfBlank.map { _ in
                .heading(size: min(max(level, 1), 6), text: richText(text, depth: depth))
            }
        case let .preformatted(code, language):
            guard let code = PresentationSanitizer.visibleText(code).nilIfBlank else { return nil }
            return .preformatted(text: .string(code), language: sanitizedLanguage(language))
        case let .list(list):
            guard depth + 2 <= maximumNestingDepth else { return flattened(block) }
            let renderedItems = list.items.enumerated().compactMap {
                index, item -> TerminalTelegramInputRichBlockListItem? in
                let rendered = item.blocks.compactMap { render($0, depth: depth + 2) }
                guard !rendered.isEmpty else { return nil }
                let number = list.number(at: index)
                return .init(
                    blocks: rendered, hasCheckbox: item.checkbox != nil, isChecked: item.checkbox == .checked,
                    value: number, type: number.map { _ in "1" }
                )
            }
            guard !renderedItems.isEmpty else { return nil }
            return .list(items: renderedItems)
        case let .quote(blocks):
            guard depth + 1 <= maximumNestingDepth else { return flattened(block) }
            let rendered = blocks.compactMap { render($0, depth: depth + 1) }
            guard !rendered.isEmpty else { return nil }
            return .blockquote(blocks: rendered)
        case let .table(table):
            guard table.columnCount <= maximumTableColumns else {
                return PresentationSanitizer.visibleText(table.plainText).nilIfBlank.map {
                    .preformatted(text: .string($0), language: nil)
                }
            }
            guard depth + 1 <= maximumNestingDepth else { return flattened(block) }
            return renderTable(table, depth: depth)
        case .divider:
            return .divider
        }
    }

    /// A block whose content would nest too deep, as one paragraph with its
    /// plain-text projection.
    private static func flattened(_ block: PresentationBlock) -> TerminalTelegramInputRichBlock? {
        PresentationSanitizer.visibleText(block.plainText).nilIfBlank.map { .paragraph(.string($0)) }
    }

    /// Every row padded to the table's column count, the header row first
    /// with its cells marked; an empty cell is sent as `""`, never omitted,
    /// because a cell without text is invisible.
    private static func renderTable(_ table: PresentationTable, depth: Int) -> TerminalTelegramInputRichBlock? {
        guard table.plainText.nilIfBlank != nil else { return nil }
        let columns = table.columnCount
        func row(_ texts: [PresentationText], isHeader: Bool) -> [TerminalTelegramInputRichBlockTableCell] {
            (0..<columns).map { column in
                let text = column < texts.count ? texts[column] : PresentationText(runs: [])
                let rendered = richText(text, depth: depth + 1)
                let cellText: TerminalTelegramRichText = if case let .array(values) = rendered, values.isEmpty {
                    .string("")
                } else {
                    rendered
                }
                let align = switch column < table.alignments.count ? table.alignments[column] : .left {
                case .left: "left"
                case .center: "center"
                case .right: "right"
                }
                return TerminalTelegramInputRichBlockTableCell(
                    text: cellText, isHeader: isHeader, align: align, valign: "top"
                )
            }
        }
        var cells: [[TerminalTelegramInputRichBlockTableCell]] = []
        if !table.header.isEmpty { cells.append(row(table.header, isHeader: true)) }
        cells += table.rows.map { row($0, isHeader: false) }
        return .table(cells: cells)
    }

    private static func richText(_ text: PresentationText, depth: Int) -> TerminalTelegramRichText {
        let values = text.runs.compactMap { renderRun($0, depth: depth) }
        if values.count == 1 { return values[0] }
        return .array(values)
    }

    /// `depth` is the level of the block or style holding the run; a style
    /// takes the next level, and one that would exceed
    /// ``maximumNestingDepth`` is sent as its plain text.
    private static func renderRun(_ run: PresentationTextRun, depth: Int) -> TerminalTelegramRichText? {
        let level = depth + 1
        guard level <= maximumNestingDepth else {
            let flattened = PresentationSanitizer.visibleText(run.plainText)
            return flattened.isEmpty ? nil : .string(flattened)
        }
        switch run {
        case let .plain(text):
            let sanitized = PresentationSanitizer.visibleText(text)
            return sanitized.isEmpty ? nil : .string(sanitized)
        case let .code(text): return .styled(type: "code", text: .string(PresentationSanitizer.visibleText(text)), url: nil)
        case let .emphasis(text): return .styled(type: "italic", text: richText(text, depth: level), url: nil)
        case let .strong(text): return .styled(type: "bold", text: richText(text, depth: level), url: nil)
        case let .strikethrough(text):
            return .styled(type: "strikethrough", text: richText(text, depth: level), url: nil)
        case let .link(label, url):
            guard allowedURL(url) else { return .string(label.plainText) }
            return .styled(type: "url", text: richText(label, depth: level), url: url.absoluteString)
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

/// `has_checkbox` and `is_checked` are `True`-typed in the Bot API: encoded
/// as `true` when set and omitted otherwise, never as `false`.
struct TerminalTelegramInputRichBlockListItem: Encodable, Sendable {
    let blocks: [TerminalTelegramInputRichBlock]
    let hasCheckbox: Bool
    let isChecked: Bool
    let value: Int?
    let type: String?

    init(
        blocks: [TerminalTelegramInputRichBlock], hasCheckbox: Bool = false, isChecked: Bool = false,
        value: Int? = nil, type: String? = nil
    ) {
        self.blocks = blocks
        self.hasCheckbox = hasCheckbox
        self.isChecked = isChecked
        self.value = value
        self.type = type
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(blocks, forKey: .blocks)
        if hasCheckbox { try container.encode(true, forKey: .hasCheckbox) }
        if isChecked { try container.encode(true, forKey: .isChecked) }
        try container.encodeIfPresent(value, forKey: .value)
        try container.encodeIfPresent(type, forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case blocks, value, type
        case hasCheckbox = "has_checkbox"
        case isChecked = "is_checked"
    }
}

/// A `table` block cell. `is_header` is `True`-typed, so it is encoded only
/// for header cells; `align` and `valign` are always sent.
struct TerminalTelegramInputRichBlockTableCell: Encodable, Sendable {
    let text: TerminalTelegramRichText
    let isHeader: Bool
    let align: String
    let valign: String

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        if isHeader { try container.encode(true, forKey: .isHeader) }
        try container.encode(align, forKey: .align)
        try container.encode(valign, forKey: .valign)
    }

    private enum CodingKeys: String, CodingKey {
        case text, align, valign
        case isHeader = "is_header"
    }
}

indirect enum TerminalTelegramInputRichBlock: Encodable, Sendable {
    case paragraph(TerminalTelegramRichText)
    case heading(size: Int, text: TerminalTelegramRichText)
    case preformatted(text: TerminalTelegramRichText, language: String?)
    case list(items: [TerminalTelegramInputRichBlockListItem])
    case blockquote(blocks: [TerminalTelegramInputRichBlock])
    case table(cells: [[TerminalTelegramInputRichBlockTableCell]])
    case divider

    /// The look of every `table` block, kept in one place until it is checked
    /// on a real client. The flags are `True`-typed in the Bot API: a set one
    /// is encoded as `true` and an unset one omitted, never sent as `false`.
    static let tableIsBordered = true
    static let tableIsStriped = false
    static let tableIsCompact = true

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
        case let .list(items):
            try container.encode("list", forKey: .type)
            try container.encode(items, forKey: .items)
        case let .blockquote(blocks):
            try container.encode("blockquote", forKey: .type)
            try container.encode(blocks, forKey: .blocks)
        case let .table(cells):
            try container.encode("table", forKey: .type)
            try container.encode(cells, forKey: .cells)
            if Self.tableIsBordered { try container.encode(true, forKey: .isBordered) }
            if Self.tableIsStriped { try container.encode(true, forKey: .isStriped) }
            if Self.tableIsCompact { try container.encode(true, forKey: .isCompact) }
        case .divider:
            try container.encode("divider", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, size, language, items, blocks, cells
        case isBordered = "is_bordered"
        case isStriped = "is_striped"
        case isCompact = "is_compact"
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
