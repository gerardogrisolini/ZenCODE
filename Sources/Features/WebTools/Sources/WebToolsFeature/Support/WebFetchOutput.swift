//  web.fetch options, the fetched-document model and the pure output assembly
//  shared by the WebKit and URLSession paths.

import Foundation
import ToolCore

enum WebFetchFormat: String, CaseIterable, Sendable {
    case markdown
    case text
    case html
}

enum WebFetchRenderMode: String, CaseIterable, Sendable {
    /// WebKit for HTML documents where available, raw otherwise.
    case auto
    /// One guarded HTTP request, no JavaScript.
    case raw
    /// Always WebKit; raw (with a note) where WebKit is unavailable.
    case rendered
}

enum WebFetchInputError: LocalizedError, Equatable, Sendable {
    case invalidOption(name: String, value: String, allowed: [String])
    case negativeOffset(Int)
    case offsetOutOfRange(offset: Int, length: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidOption(name, value, allowed):
            "Invalid \(name) '\(value)'. Expected one of: \(allowed.joined(separator: ", "))."
        case let .negativeOffset(offset):
            "offset must be 0 or greater (got \(offset))."
        case let .offsetOutOfRange(offset, length) where length == 0:
            "offset \(offset) is past the end of the content: the content is empty (total length 0 bytes)."
        case let .offsetOutOfRange(offset, length):
            "offset \(offset) is past the end of the content: the total length is \(length) bytes, "
                + "so offset must be below \(length)."
        }
    }
}

/// Validated, clamped `web.fetch` options.
struct WebFetchOptions: Sendable, Equatable {
    static let defaultMaxBytes = 120_000
    static let maxBytesRange = 1_024...1_000_000
    static let defaultTimeoutSeconds = 20
    static let timeoutRange = 1...120
    static let maxLinks = 80
    /// Body bytes read by the raw path whatever `maxBytes` is: the content is
    /// converted (and paged with `offset`) from the whole document.
    static let downloadLimit = 8 * 1024 * 1024

    var maxBytes = defaultMaxBytes
    var timeout = TimeInterval(defaultTimeoutSeconds)
    var format: WebFetchFormat = .markdown
    var offset = 0
    var includeLinks = true
    var mainContentOnly = true
    var selector: String?
    var render: WebFetchRenderMode = .auto
    /// Set when `selector` was given, or `mainContentOnly: false` was passed,
    /// with `format: html` (the HTML is returned whole).
    var ignoresScopeForHTML = false

    init() {}

    init(_ input: WebFetchTool.Input) throws {
        maxBytes = min(max(input.maxBytes ?? Self.defaultMaxBytes, Self.maxBytesRange.lowerBound), Self.maxBytesRange.upperBound)
        let seconds = min(max(input.timeoutSeconds ?? Self.defaultTimeoutSeconds, Self.timeoutRange.lowerBound), Self.timeoutRange.upperBound)
        timeout = TimeInterval(seconds)
        format = try Self.parse(input.format, name: "format", default: .markdown)
        render = try Self.parse(input.render, name: "render", default: .auto)
        offset = input.offset ?? 0
        guard offset >= 0 else { throw WebFetchInputError.negativeOffset(offset) }
        includeLinks = input.includeLinks ?? true
        mainContentOnly = input.mainContentOnly ?? true
        selector = input.selector?.nilIfBlank
        // A typo fails here, before any network request.
        if let selector, WebCSSSelector(selector) == nil {
            throw WebContentError.invalidSelector(selector)
        }
        ignoresScopeForHTML = format == .html && (selector != nil || input.mainContentOnly == false)
    }

    /// Case-insensitive enum parsing; blank or missing means the default.
    static func parse<Value: RawRepresentable & CaseIterable>(
        _ raw: String?,
        name: String,
        default defaultValue: Value
    ) throws -> Value where Value.RawValue == String {
        guard let trimmed = raw?.nilIfBlank else {
            return defaultValue
        }
        guard let value = Value(rawValue: trimmed.lowercased()) else {
            throw WebFetchInputError.invalidOption(name: name, value: trimmed, allowed: Value.allCases.map(\.rawValue))
        }
        return value
    }

    /// Converter options for an HTML document located at `pageURL`.
    func markdownOptions(pageURL: URL?) -> WebMarkdownOptions {
        WebMarkdownOptions(
            baseURL: pageURL,
            pageURL: pageURL,
            mainContentOnly: mainContentOnly,
            selector: selector,
            includeLinks: includeLinks,
            maxLinks: Self.maxLinks,
            format: format == .text ? .text : .markdown
        )
    }
}

/// What a fetch produced, before slicing and formatting.
struct WebFetchDocument: Sendable {
    enum Engine: Sendable {
        case webKit
        case urlSession

        var label: String {
            switch self {
            case .webKit: "WebKit (rendered, JavaScript executed)"
            case .urlSession: "URLSession (raw fetch)"
            }
        }
    }

    enum Body: Sendable {
        /// Text content, sliced with `offset`/`maxBytes`. `isComplete` is
        /// false when extraction stopped early (PDF page or byte budget), so
        /// `length` is only a lower bound.
        case content(String, isComplete: Bool)
        /// A fixed explanation instead of content (binary data, no extractor).
        case message(String)
    }

    struct HeaderLine: Sendable, Equatable {
        let name: String
        let value: String
    }

    var url: String
    var status: Int?
    var title: String?
    var engine: Engine
    var contentType: String
    /// `main (article)`, `full page`, `selector h1` — HTML conversions only.
    var scope: String?
    var description: String?
    var body: Body
    var links: [WebExtractedLink] = []
    /// Rendered as leading `note:` lines.
    var notes: [String] = []
    /// Extra header lines after `content-type`/`scope` (e.g. `pages`, `bytes`).
    var extraHeaders: [HeaderLine] = []

    static func scopeLabel(_ scope: WebMarkdownConversion.Scope) -> String {
        switch scope {
        case .mainContent(let name):
            "main (\(name.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))))"
        case .fullPage:
            "full page"
        case .selector(let selector):
            "selector \(selector)"
        }
    }
}

/// A byte window of the content; `start`/`end` are UTF-8 offsets.
struct WebContentSlice: Sendable, Equatable {
    let text: String
    let start: Int
    let end: Int
    let total: Int

    var isTruncated: Bool {
        end < total
    }
}

enum WebFetchOutput {
    static let maxLinkTextLength = 160

    /// Cuts `maxBytes` of UTF-8 starting at `offset`. An offset inside a
    /// multi-byte character moves back to that character's first byte; the
    /// end never splits a Unicode scalar (see ``WebFetchTool/truncated(_:toBytes:)``).
    static func slice(_ content: String, offset: Int, maxBytes: Int) throws -> WebContentSlice {
        let utf8 = content.utf8
        let total = utf8.count
        guard offset >= 0 else { throw WebFetchInputError.negativeOffset(offset) }
        if offset > 0, offset >= total {
            throw WebFetchInputError.offsetOutOfRange(offset: offset, length: total)
        }
        var startIndex = utf8.index(utf8.startIndex, offsetBy: offset)
        while startIndex > utf8.startIndex, !utf8[startIndex].isUTF8ScalarStart {
            startIndex = utf8.index(before: startIndex)
        }
        let start = utf8.distance(from: utf8.startIndex, to: startIndex)
        let remainder = start == 0 ? content : String(decoding: utf8[startIndex...], as: UTF8.self)
        let text = WebFetchTool.truncated(remainder, toBytes: maxBytes)
        return WebContentSlice(text: text, start: start, end: start + text.utf8.count, total: total)
    }

    /// The tool output for `document`: `note:` lines, the header, the content
    /// slice, a continuation hint when truncated, and the links (first call only).
    static func render(_ document: WebFetchDocument, options: WebFetchOptions) throws -> String {
        var lines = document.notes.map { "note: \($0)" }
        lines.append("url: \(document.url)")
        if let status = document.status {
            lines.append("status: \(status)")
        }
        if let title = document.title?.nilIfBlank {
            lines.append("title: \(title)")
        }
        lines.append("engine: \(document.engine.label)")
        lines.append("content-type: \(document.contentType)")
        if let scope = document.scope {
            lines.append("scope: \(scope)")
        }
        for header in document.extraHeaders {
            lines.append("\(header.name): \(header.value)")
        }

        switch document.body {
        case .message(let message):
            lines.append("")
            lines.append(message)
            return lines.joined(separator: "\n")
        case let .content(content, isComplete):
            let slice = try slice(content, offset: options.offset, maxBytes: options.maxBytes)
            lines.append("length: \(slice.total)" + (isComplete ? "" : " (partial: extraction stopped early)"))
            if slice.start > 0 || slice.isTruncated {
                lines.append("range: \(slice.start)-\(slice.end)")
            }
            if let description = document.description?.nilIfBlank {
                lines.append("description: \(description)")
            }
            lines.append("")
            lines.append(slice.text.isEmpty ? "(no content)" : slice.text)
            if slice.isTruncated {
                let omitted = slice.total - slice.end
                let amount = isComplete ? "\(omitted) bytes" : "at least \(omitted) bytes"
                lines.append("")
                lines.append("<truncated: \(amount) omitted; call again with offset=\(slice.end) to continue>")
            }
            if options.includeLinks, options.offset == 0, options.format != .html, !document.links.isEmpty {
                lines.append("")
                lines.append("## Links")
                for link in document.links {
                    lines.append("- [\(linkText(link.text))](\(link.url))")
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    /// One line, brackets escaped, at most ``maxLinkTextLength`` characters.
    static func linkText(_ text: String) -> String {
        var value = WebMarkdownRenderer.collapsedText(text)
        if value.count > maxLinkTextLength {
            value = String(value.prefix(maxLinkTextLength - 1)) + "…"
        }
        return value
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
    }
}

extension UInt8 {
    /// True when a UTF-8 code unit begins a scalar (not a continuation byte).
    var isUTF8ScalarStart: Bool { self & 0xC0 != 0x80 }
}
