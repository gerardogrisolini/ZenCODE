//
//  PresentationDocument.swift
//  ZenCODE
//

import Foundation
import Markdown

/// Backend-neutral presentation tree. It is deliberately transient and contains
/// only user-visible content: transport metadata, reasoning and tool payloads have
/// no representation here.
struct PresentationDocument: Sendable, Equatable {
    var blocks: [PresentationBlock]

    init(blocks: [PresentationBlock]) {
        self.blocks = blocks
    }

    init(markdown: String) {
        var renderer = PresentationMarkdownRenderer()
        blocks = renderer.visit(Document(parsing: PresentationSanitizer.visibleText(markdown)))
    }

    var plainText: String {
        blocks.map(\.plainText).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

enum PresentationBlock: Sendable, Equatable {
    case paragraph(PresentationText)
    case heading(level: Int, text: PresentationText)
    case preformatted(code: String, language: String?)
    case list(ordered: Bool, items: [[PresentationBlock]])
    case details(summary: PresentationText, blocks: [PresentationBlock], isOpen: Bool)
    case buttons([PresentationButton])
    case document(PresentationDocumentReference, caption: PresentationText?)

    var plainText: String {
        switch self {
        case let .paragraph(text): text.plainText
        case let .heading(_, text): text.plainText
        case let .preformatted(code, _): code
        case let .list(ordered, items):
            items.enumerated().map { index, blocks in
                let marker = ordered ? "\(index + 1)." : "•"
                let body = blocks.map(\.plainText).joined(separator: "\n")
                return "\(marker) \(body)"
            }.joined(separator: "\n")
        case let .details(summary, blocks, _):
            ([summary.plainText] + blocks.map(\.plainText)).filter { !$0.isEmpty }.joined(separator: "\n")
        case let .buttons(buttons): buttons.map(\.label).joined(separator: " · ")
        case let .document(document, caption):
            [caption?.plainText, document.filename].compactMap { $0 }.joined(separator: " — ")
        }
    }
}

struct PresentationText: Sendable, Equatable {
    var runs: [PresentationTextRun]

    init(_ plainText: String) {
        runs = [.plain(PresentationSanitizer.visibleText(plainText))]
    }

    init(runs: [PresentationTextRun]) {
        self.runs = runs
    }

    var plainText: String { runs.map(\.plainText).joined() }
}

enum PresentationTextRun: Sendable, Equatable {
    case plain(String)
    case code(String)
    case emphasis(PresentationText)
    case strong(PresentationText)
    case link(label: PresentationText, url: URL)

    var plainText: String {
        switch self {
        case let .plain(text), let .code(text): text
        case let .emphasis(text), let .strong(text): text.plainText
        case let .link(label, _): label.plainText
        }
    }
}

struct PresentationButton: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case url(URL)
        case callback(String)
    }
    enum Style: String, Sendable, Equatable { case danger, success, primary, link }

    let label: String
    let action: Action
    let style: Style?
}

/// A backend-independent reference to an already-uploaded document. Local paths
/// and bytes are intentionally excluded, preventing presentation from becoming an
/// upload/exfiltration channel.
struct PresentationDocumentReference: Sendable, Equatable {
    let remoteID: String
    let filename: String?
}

enum PresentationSanitizer {
    /// Removes wire-invisible controls and bidi overrides while retaining normal
    /// whitespace. This protects client rendering without trying to redact the
    /// caller's already-approved visible answer.
    static func visibleText(_ value: String) -> String {
        let forbidden = CharacterSet(charactersIn:
            "\u{0000}\u{0001}\u{0002}\u{0003}\u{0004}\u{0005}\u{0006}\u{0007}\u{0008}\u{000B}\u{000C}\u{000E}\u{000F}" +
            "\u{0010}\u{0011}\u{0012}\u{0013}\u{0014}\u{0015}\u{0016}\u{0017}\u{0018}\u{0019}\u{001A}\u{001B}\u{001C}\u{001D}\u{001E}\u{001F}" +
            "\u{007F}\u{202A}\u{202B}\u{202D}\u{202E}\u{202C}\u{2066}\u{2067}\u{2068}\u{2069}"
        )
        return value.unicodeScalars.filter { !forbidden.contains($0) }.map(String.init).joined()
    }
}

private struct PresentationMarkdownRenderer: MarkupVisitor {
    typealias Result = [PresentationBlock]

    mutating func defaultVisit(_ markup: Markup) -> [PresentationBlock] {
        markup.children.flatMap { visit($0) }
    }

    mutating func visitDocument(_ document: Document) -> [PresentationBlock] {
        document.children.flatMap { visit($0) }
    }

    mutating func visitParagraph(_ paragraph: Paragraph) -> [PresentationBlock] {
        [.paragraph(renderInline(paragraph))]
    }

    mutating func visitHeading(_ heading: Heading) -> [PresentationBlock] {
        [.heading(level: min(max(heading.level, 1), 6), text: renderInline(heading))]
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> [PresentationBlock] {
        let code = codeBlock.code.hasSuffix("\n") ? String(codeBlock.code.dropLast()) : codeBlock.code
        return [.preformatted(code: PresentationSanitizer.visibleText(code), language: codeBlock.language)]
    }

    mutating func visitUnorderedList(_ unorderedList: UnorderedList) -> [PresentationBlock] {
        [.list(ordered: false, items: unorderedList.listItems.map { item in item.children.flatMap { visit($0) } })]
    }

    mutating func visitOrderedList(_ orderedList: OrderedList) -> [PresentationBlock] {
        [.list(ordered: true, items: orderedList.listItems.map { item in item.children.flatMap { visit($0) } })]
    }

    private func renderInline(_ markup: Markup) -> PresentationText {
        PresentationText(runs: markup.children.flatMap(renderRun))
    }

    private func renderRun(_ markup: Markup) -> [PresentationTextRun] {
        if let text = markup as? Text { return [.plain(PresentationSanitizer.visibleText(text.string))] }
        if let code = markup as? InlineCode { return [.code(PresentationSanitizer.visibleText(code.code))] }
        if let emphasis = markup as? Emphasis {
            return [.emphasis(PresentationText(runs: emphasis.children.flatMap(renderRun)))]
        }
        if let strong = markup as? Strong {
            return [.strong(PresentationText(runs: strong.children.flatMap(renderRun)))]
        }
        if let link = markup as? Link,
           let destination = link.destination,
           let url = URL(string: destination),
           ["https", "http", "tg"].contains(url.scheme?.lowercased()) {
            return [.link(label: PresentationText(runs: link.children.flatMap(renderRun)), url: url)]
        }
        if markup is SoftBreak { return [.plain("\n")] }
        if markup is LineBreak { return [.plain("\n")] }
        return markup.children.flatMap(renderRun)
    }
}
