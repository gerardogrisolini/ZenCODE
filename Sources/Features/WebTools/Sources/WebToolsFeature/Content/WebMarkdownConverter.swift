import Foundation

enum WebContentError: LocalizedError, Equatable, Sendable {
    case invalidSelector(String)
    case selectorMatchedNothing(String)

    var errorDescription: String? {
        switch self {
        case .invalidSelector(let selector):
            "Invalid or unsupported CSS selector: \(selector). Supported: tag, *, #id, .class, [attr], "
                + "[attr=v], [attr^=v], [attr$=v], [attr*=v], [attr~=v], [attr|=v], descendant and '>' "
                + "combinators, comma-separated groups."
        case .selectorMatchedNothing(let selector):
            "CSS selector matched no elements: \(selector)"
        }
    }
}

enum WebContentFormat: String, Sendable {
    case markdown
    case text
}

struct WebExtractedLink: Sendable, Hashable {
    let text: String
    let url: String
}

struct WebMarkdownConversion: Sendable {
    enum Scope: Sendable, Equatable {
        /// The tag or role used, e.g. `"main"`, `"[role=main]"`, `"article"`.
        case mainContent(String)
        case fullPage
        case selector(String)
    }

    /// `<title>` collapsed, else the first `<h1>`, else "".
    let title: String
    /// Markdown or plain text, per ``WebMarkdownOptions/format``.
    let content: String
    let links: [WebExtractedLink]
    let scope: Scope
    /// `<meta name=description>` or `og:description`, collapsed.
    let description: String?
    /// `<link rel=canonical href>` resolved against the document base URL.
    let canonicalURL: String?
}

struct WebMarkdownOptions: Sendable {
    /// Resolves relative hrefs/srcs; a `<base href>` in the document overrides it.
    var baseURL: URL? = nil
    /// Address of the document itself. Links to it (ignoring the fragment),
    /// such as same-page anchors and cite notes, render as plain text and are
    /// left out of `links`. Defaults to `baseURL` when nil.
    var pageURL: URL? = nil
    /// Converts the main-content element only and strips navigation,
    /// sidebars, footers, menus and dialogs, also inside that element.
    var mainContentOnly: Bool = true
    /// When set (non-blank), `mainContentOnly` is ignored.
    var selector: String? = nil
    /// When false, `links` is empty and anchors render as plain text.
    var includeLinks: Bool = true
    var maxLinks: Int = 80
    var format: WebContentFormat = .markdown
}

/// Platform-independent HTML -> Markdown / plain-text conversion built on
/// ``WebHTMLParser``. Pure Foundation, linear time, iterative traversal.
enum WebMarkdownConverter {
    /// Minimum collapsed text length (UTF-8 bytes) for a main-content candidate.
    static let mainContentMinimumLength = 200
    /// Minimum share of the body's text for a main-content candidate.
    static let mainContentMinimumShare = 0.2

    static func convert(html: String, options: WebMarkdownOptions = .init()) throws -> WebMarkdownConversion {
        let document = WebHTMLParser.parse(html)
        let survey = WebDocumentSurvey(document: document)
        let baseURL = survey.documentBaseURL(fallback: options.baseURL)
        var renderer = WebMarkdownRenderer(
            format: options.format,
            includeLinks: options.includeLinks,
            maxLinks: options.maxLinks,
            baseURL: baseURL,
            pageURL: options.pageURL ?? options.baseURL
        )

        let scope: WebMarkdownConversion.Scope
        let selector = options.selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selector.isEmpty {
            let matches = try WebCSSSelector.select(selector, in: document)
            guard !matches.isEmpty else {
                throw WebContentError.selectorMatchedNothing(selector)
            }
            // The caller chose exact elements: nothing inside them is stripped.
            for match in matches {
                renderer.render(match, landmarks: .keep)
            }
            scope = .selector(selector)
        } else {
            let pageRoot = survey.body ?? document
            if options.mainContentOnly, let main = survey.mainContent(pageRoot: pageRoot) {
                renderer.render(main.node, landmarks: .insideMainContent)
                scope = .mainContent(main.name)
            } else {
                renderer.render(pageRoot, landmarks: options.mainContentOnly ? .fullPage : .keep)
                scope = .fullPage
            }
        }

        let metadata = survey.metadata(baseURL: baseURL)
        return WebMarkdownConversion(
            title: metadata.title,
            content: renderer.finish(),
            links: renderer.links,
            scope: scope,
            description: metadata.description,
            canonicalURL: metadata.canonicalURL
        )
    }

    /// Title, description and canonical URL only, without rendering; used
    /// when the HTML itself is returned.
    static func metadata(html: String, baseURL: URL? = nil) -> WebHTMLMetadata {
        let document = WebHTMLParser.parse(html)
        let survey = WebDocumentSurvey(document: document)
        return survey.metadata(baseURL: survey.documentBaseURL(fallback: baseURL))
    }
}

struct WebHTMLMetadata: Sendable, Equatable {
    /// `<title>` collapsed, else the first `<h1>`, else "".
    let title: String
    let description: String?
    let canonicalURL: String?
}

// MARK: - Document survey

/// One iterative pass collecting head metadata and main-content candidates.
private struct WebDocumentSurvey {
    var title: String?
    var firstHeading: WebHTMLNode?
    var description: String?
    var ogDescription: String?
    var canonicalHref: String?
    var baseHref: String?
    var body: WebHTMLNode?
    var mains: [WebHTMLNode] = []
    var roleMains: [WebHTMLNode] = []
    var articles: [WebHTMLNode] = []

    init(document: WebHTMLNode) {
        var stack: [(node: WebHTMLNode, hidden: Bool)] = [(document, false)]
        while let (node, hidden) = stack.popLast() {
            guard case .element(let name) = node.kind else {
                if case .document = node.kind {
                    stack.append(contentsOf: node.children.reversed().map { ($0, false) })
                }
                continue
            }
            // Foreign content has its own <title>; template content is inert.
            if name == "svg" || name == "math" || name == "template" {
                continue
            }
            let skipped = hidden || WebMarkdownRenderer.isSkipped(node, name)
            switch name {
            case "title":
                if title?.isEmpty ?? true {
                    title = WebMarkdownRenderer.collapsedText(decoding: node.textContent)
                }
            case "meta":
                collectMeta(node)
            case "link":
                if canonicalHref == nil,
                   let rel = node.attributes["rel"],
                   WebMarkdownRenderer.tokens(rel).contains("canonical"),
                   let href = node.attributes["href"],
                   !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    canonicalHref = href
                }
            case "base":
                if baseHref == nil,
                   let href = node.attributes["href"],
                   !href.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    baseHref = href
                }
            case "body":
                if body == nil { body = node }
            case "main":
                if !skipped { mains.append(node) }
            case "article":
                if !skipped { articles.append(node) }
            case "h1":
                if !skipped, firstHeading == nil { firstHeading = node }
            default:
                break
            }
            if !skipped, name != "main", let role = node.attributes["role"],
               WebMarkdownRenderer.tokens(role).contains("main") {
                roleMains.append(node)
            }
            if !node.children.isEmpty {
                stack.append(contentsOf: node.children.reversed().map { ($0, skipped) })
            }
        }
    }

    private mutating func collectMeta(_ node: WebHTMLNode) {
        guard let content = node.attributes["content"] else { return }
        let name = node.attributes["name"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let property = node.attributes["property"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let value = WebMarkdownRenderer.collapsedText(content)
        guard !value.isEmpty else { return }
        if description == nil, name == "description" {
            description = value
        }
        if ogDescription == nil, property == "og:description" || name == "og:description" {
            ogDescription = value
        }
    }

    func metadata(baseURL: URL?) -> WebHTMLMetadata {
        var title = self.title ?? ""
        if title.isEmpty, let heading = firstHeading {
            title = WebMarkdownRenderer.visibleText(of: heading)
        }
        let canonicalURL = canonicalHref.flatMap { href in
            WebMarkdownRenderer.resolve(href, against: baseURL)?.absoluteString
        }
        return WebHTMLMetadata(title: title, description: description ?? ogDescription, canonicalURL: canonicalURL)
    }

    func documentBaseURL(fallback: URL?) -> URL? {
        guard let baseHref, let resolved = WebMarkdownRenderer.resolve(baseHref, against: fallback) else {
            return fallback
        }
        return resolved
    }

    /// First candidate group (`main`, `[role=main]`, `article`) whose largest
    /// member is long enough in absolute terms and relative to the page.
    func mainContent(pageRoot: WebHTMLNode) -> (node: WebHTMLNode, name: String)? {
        let pageLength = WebMarkdownRenderer.visibleText(of: pageRoot).utf8.count
        let groups: [(String, [WebHTMLNode])] = [("main", mains), ("[role=main]", roleMains), ("article", articles)]
        for (name, nodes) in groups {
            var best: (node: WebHTMLNode, length: Int)?
            for node in nodes {
                let length = WebMarkdownRenderer.visibleText(of: node).utf8.count
                if length > (best?.length ?? -1) {
                    best = (node, length)
                }
            }
            guard let best else { continue }
            if best.length >= WebMarkdownConverter.mainContentMinimumLength,
               Double(best.length) >= WebMarkdownConverter.mainContentMinimumShare * Double(pageLength) {
                return (best.node, name)
            }
        }
        return nil
    }
}

// MARK: - Renderer

/// Event-driven renderer: the DOM is walked with an explicit enter/exit step
/// stack, inline content accumulates in a byte buffer with HTML whitespace
/// collapsing, and block containers (lists, quotes, tables, ...) are frames
/// that compose their children's lines when they close.
struct WebMarkdownRenderer {
    enum BlockKind: Equatable {
        /// Separated by a blank line everywhere (p, headings, pre, tables...).
        case paragraph
        /// Generic flow content (div, bare text); tight inside list items.
        case flow
        case list
        case listItem
        case term
        case definition
    }

    struct Block {
        var lines: [String]
        var kind: BlockKind
        /// Continuation indent of a list item (its marker width).
        var indent = 0
    }

    enum FrameKind: Equatable {
        case root
        case blockquote
        case list
        case listItem
        case definitionList
        case term
        case definition
        case heading
        case table
        case row
        case cell
        case summary
        case preformatted
    }

    struct TableRow {
        var cells: [String]
        var isHeader: Bool
    }

    struct Frame {
        let kind: FrameKind
        var blocks: [Block] = []
        var ordered = false
        var nextNumber = 1
        var marker = ""
        var level = 0
        var rows: [TableRow] = []
        var cells: [String] = []
        var headerCellCount = 0
        var inTableHead = false
        var isHeaderCell = false
        var savedTableHeadDepth = 0
        var language: String?

        init(kind: FrameKind) {
            self.kind = kind
        }

        /// Collapse frames flatten every child block into one line.
        var collapses: Bool {
            switch kind {
            case .heading, .term, .cell, .summary: true
            default: false
            }
        }
    }

    enum WrapperKind: Equatable {
        case strong
        case emphasis
        case strikethrough
        case code
        case link(String)
    }

    struct Wrapper {
        let kind: WrapperKind
        /// Whether the wrapper has been applied to some content yet.
        var produced = false
        /// For links: a truly empty anchor (no element children) renders its
        /// URL; one whose children (icons, alt-less images) produced no text
        /// renders nothing.
        var rendersURLWhenEmpty = false
    }

    enum ExitAction {
        case none
        case endBlock(BlockKind)
        case popFrame
        case closeWrapper
        case endTableHead
        /// End of a layout table: its rows were ordinary blocks.
        case endLayoutTable
        /// End of a layout-table cell: the next cell's text is space-separated.
        case separateCell
        /// End of a block inside a layout cell (see ``deferredFlush``).
        case endDeferredBlock(BlockKind, startCount: Int, wasDeferred: Bool)
    }

    /// Which boilerplate landmarks below the rendered root are dropped. The
    /// root itself is never dropped.
    enum LandmarkMode {
        /// Keep everything (selector matches, `mainContentOnly == false`).
        case keep
        /// Inside a main-content element: navigation, sidebars, footers,
        /// menus, dialogs and alerts, plus headers that hold a `<nav>`.
        /// Other headers usually carry the article title and are kept.
        case insideMainContent
        /// Whole-body fallback: the above plus every header and banner.
        case fullPage
    }

    enum Step {
        case enter(WebHTMLNode)
        case exit(ExitAction)
    }

    let format: WebContentFormat
    let includeLinks: Bool
    let maxLinks: Int
    let baseURL: URL?
    private let pageURLKey: String?
    private(set) var links: [WebExtractedLink] = []
    private var seenLinkURLs: Set<String> = []

    private var frames: [Frame] = [Frame(kind: .root)]
    /// Inline content of the paragraph being built in the top frame.
    private var inline: [UInt8] = []
    private var pendingSpace = false
    /// Open inline wrappers (outermost first) and, for the current paragraph,
    /// the content start offset of each wrapper applied so far (a prefix).
    private var wrappers: [Wrapper] = []
    private var applied: [Int] = []
    private var preformatted: [UInt8] = []
    private var preDepth = 0
    private var codeDepth = 0
    private var tableHeadDepth = 0
    /// One entry per open table, innermost last.
    private var openTables: [OpenTable] = []
    /// Inside layout cells a block boundary is deferred: the text before a
    /// block is ended only once the block produces content, so empty
    /// decorative blocks (icons, spacers) do not split a row.
    private var deferredFlush = false
    /// Incremented whenever inline content, a block or a frame is produced.
    private var producedCount = 0

    struct OpenTable {
        var isLayout: Bool
        /// Layout cells currently open in this table.
        var openCells = 0
    }

    init(format: WebContentFormat, includeLinks: Bool, maxLinks: Int, baseURL: URL?, pageURL: URL?) {
        self.format = format
        self.includeLinks = includeLinks
        self.maxLinks = maxLinks
        self.baseURL = baseURL
        self.pageURLKey = pageURL.map { Self.withoutFragment($0.absoluteString) }
    }

    private var isMarkdown: Bool {
        format == .markdown
    }

    // MARK: Traversal

    private var inLayoutTable: Bool {
        openTables.last?.isLayout == true
    }

    private var inLayoutCell: Bool {
        guard let table = openTables.last else { return false }
        return table.isLayout && table.openCells > 0
    }

    mutating func render(_ root: WebHTMLNode, landmarks: LandmarkMode) {
        var steps: [Step] = [.enter(root)]
        while let step = steps.popLast() {
            switch step {
            case .exit(let action):
                finish(action)
            case .enter(let node):
                switch node.kind {
                case .text(let raw):
                    appendText(raw)
                case .comment:
                    break
                case .document:
                    for child in node.children.reversed() {
                        steps.append(.enter(child))
                    }
                case .element(let name):
                    if Self.isSkipped(node, name) || (node !== root && Self.isLandmark(node, name, mode: landmarks)) {
                        break
                    }
                    steps.append(.exit(enter(node, name)))
                    for child in node.children.reversed() {
                        steps.append(.enter(child))
                    }
                }
            }
        }
        flushInline(.flow)
    }

    /// Final output: blocks separated by single blank lines, trimmed.
    func finish() -> String {
        let lines = Self.compose(frames[0].blocks, style: .loose)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func enter(_ node: WebHTMLNode, _ name: String) -> ExitAction {
        if preDepth > 0 {
            return enterPreformatted(node, name)
        }
        switch name {
        case "br":
            lineBreak()
            return .none
        case "wbr":
            return .none
        case "hr":
            flushInline(.flow)
            appendBlock(Block(lines: ["---"], kind: .paragraph))
            return .none
        case "img":
            appendImage(node)
            return .none
        case "p":
            if inLayoutCell {
                return deferBlock(.paragraph)
            }
            flushInline(.flow)
            return .endBlock(.paragraph)
        case "h1", "h2", "h3", "h4", "h5", "h6":
            var frame = Frame(kind: .heading)
            frame.level = Int(String(name.dropFirst())) ?? 1
            return pushFrame(frame)
        case "blockquote":
            return pushFrame(Frame(kind: .blockquote))
        case "ul", "ol", "menu", "dir":
            var frame = Frame(kind: .list)
            frame.ordered = name == "ol"
            if frame.ordered, let start = node.attributes["start"].flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }) {
                frame.nextNumber = start
            }
            return pushFrame(frame)
        case "li":
            flushInline(.flow)
            var marker = "- "
            let top = frames.count - 1
            if frames[top].kind == .list, frames[top].ordered {
                marker = "\(frames[top].nextNumber). "
                frames[top].nextNumber += 1
            }
            var frame = Frame(kind: .listItem)
            frame.marker = marker
            return pushFrame(frame)
        case "dl":
            return pushFrame(Frame(kind: .definitionList))
        case "dt":
            return pushFrame(Frame(kind: .term))
        case "dd":
            return pushFrame(Frame(kind: .definition))
        case "table":
            guard Self.isDataTable(node) else {
                // Layout table: rows become ordinary blocks, cells run inline.
                flushInline(.flow)
                openTables.append(OpenTable(isLayout: true))
                return .endLayoutTable
            }
            openTables.append(OpenTable(isLayout: false))
            var frame = Frame(kind: .table)
            frame.savedTableHeadDepth = tableHeadDepth
            tableHeadDepth = 0
            return pushFrame(frame)
        case "thead":
            flushInline(.flow)
            tableHeadDepth += 1
            return .endTableHead
        case "tr":
            if inLayoutTable {
                flushInline(.flow)
                return .endBlock(.flow)
            }
            var frame = Frame(kind: .row)
            frame.inTableHead = tableHeadDepth > 0
            return pushFrame(frame)
        case "td", "th":
            if inLayoutTable {
                openTables[openTables.count - 1].openCells += 1
                pendingSpace = true
                return .separateCell
            }
            var frame = Frame(kind: .cell)
            frame.isHeaderCell = name == "th"
            return pushFrame(frame)
        case "pre":
            var frame = Frame(kind: .preformatted)
            frame.language = Self.codeLanguage(of: node)
            let action = pushFrame(frame)
            preDepth += 1
            preformatted.removeAll(keepingCapacity: true)
            return action
        case "summary":
            return pushFrame(Frame(kind: .summary))
        case "strong", "b":
            return openWrapper(.strong)
        case "em", "i":
            return openWrapper(.emphasis)
        case "del", "s", "strike":
            return openWrapper(.strikethrough)
        case "code":
            return openWrapper(.code)
        case "a":
            return openLink(node)
        default:
            if Self.blockElements.contains(name) {
                if inLayoutCell {
                    return deferBlock(.flow)
                }
                flushInline(.flow)
                return .endBlock(.flow)
            }
            return .none
        }
    }

    /// Starts a block inside a layout cell without ending the current text yet.
    private mutating func deferBlock(_ kind: BlockKind) -> ExitAction {
        let action = ExitAction.endDeferredBlock(kind, startCount: producedCount, wasDeferred: deferredFlush)
        deferredFlush = true
        return action
    }

    /// Inside `<pre>` only text, line breaks and the code language matter.
    private mutating func enterPreformatted(_ node: WebHTMLNode, _ name: String) -> ExitAction {
        switch name {
        case "br":
            preformatted.append(0x0A)
        case "code", "pre", "samp", "kbd":
            let top = frames.count - 1
            if frames[top].language == nil {
                frames[top].language = Self.codeLanguage(of: node)
            }
        default:
            break
        }
        return .none
    }

    private mutating func finish(_ action: ExitAction) {
        switch action {
        case .none:
            break
        case .endBlock(let kind):
            flushInline(kind)
        case .popFrame:
            popFrame()
        case .closeWrapper:
            closeWrapper()
        case .endTableHead:
            flushInline(.flow)
            tableHeadDepth = max(0, tableHeadDepth - 1)
        case .endLayoutTable:
            flushInline(.flow)
            if !openTables.isEmpty {
                openTables.removeLast()
            }
        case .separateCell:
            if let last = openTables.indices.last {
                openTables[last].openCells = max(0, openTables[last].openCells - 1)
            }
            pendingSpace = true
        case let .endDeferredBlock(kind, startCount, wasDeferred):
            if producedCount == startCount {
                // The block rendered nothing: it only separates words.
                deferredFlush = wasDeferred
                pendingSpace = true
            } else {
                flushInline(kind)
            }
        }
    }

    // MARK: Inline content

    private mutating func appendText(_ raw: String) {
        var text = raw
        if preDepth > 0 {
            text.withUTF8 { appendPreformattedText($0) }
            return
        }
        text.withUTF8 { buffer in
            guard buffer.contains(Self.ampersand) else {
                appendCollapsed(buffer)
                return
            }
            var decoded: [UInt8] = []
            decoded.reserveCapacity(buffer.count)
            WebHTMLEntities.appendDecoded(buffer, to: &decoded)
            decoded.withUnsafeBufferPointer { appendCollapsed($0) }
        }
    }

    /// Appends text collapsing runs of HTML whitespace (and no-break spaces)
    /// into one pending space that only materializes before more content.
    private mutating func appendCollapsed(_ buffer: UnsafeBufferPointer<UInt8>) {
        let count = buffer.count
        var index = 0
        while index < count {
            let width = Self.whitespaceWidth(buffer, at: index)
            if width > 0 {
                pendingSpace = true
                index += width
                continue
            }
            var end = index + 1
            while end < count, Self.whitespaceWidth(buffer, at: end) == 0 {
                end += 1
            }
            beginContent()
            inline.append(contentsOf: UnsafeBufferPointer(rebasing: buffer[index..<end]))
            index = end
        }
    }

    private mutating func appendPreformattedText(_ buffer: UnsafeBufferPointer<UInt8>) {
        var decoded: [UInt8] = []
        if buffer.contains(Self.ampersand) {
            decoded.reserveCapacity(buffer.count)
            WebHTMLEntities.appendDecoded(buffer, to: &decoded)
        } else {
            decoded.append(contentsOf: buffer)
        }
        guard decoded.contains(0x0D) || decoded.contains(0xC2) else {
            preformatted.append(contentsOf: decoded)
            return
        }
        var index = 0
        while index < decoded.count {
            let byte = decoded[index]
            if byte == 0x0D {
                // CRLF and lone CR become LF.
                preformatted.append(0x0A)
                if index + 1 < decoded.count, decoded[index + 1] == 0x0A {
                    index += 1
                }
            } else if byte == 0xC2, index + 1 < decoded.count, decoded[index + 1] == 0xA0 {
                preformatted.append(0x20)
                index += 1
            } else {
                preformatted.append(byte)
            }
            index += 1
        }
    }

    /// Materializes a pending space and applies open wrappers that are not
    /// yet applied to the current paragraph. Called right before content.
    private mutating func beginContent() {
        if deferredFlush {
            // Content inside a deferred block: end the text before it first.
            flushInline(.flow)
        }
        producedCount += 1
        if pendingSpace {
            pendingSpace = false
            if let last = inline.last, last != 0x20, last != 0x0A {
                inline.append(0x20)
            }
        }
        guard applied.count < wrappers.count else { return }
        for index in applied.count..<wrappers.count {
            if let marker = Self.marker(for: wrappers[index].kind) {
                inline.append(contentsOf: marker)
            }
            applied.append(inline.count)
            wrappers[index].produced = true
        }
    }

    private mutating func appendInlineContent(_ text: String) {
        beginContent()
        inline.append(contentsOf: text.utf8)
    }

    private mutating func lineBreak() {
        if frames[frames.count - 1].collapses {
            pendingSpace = true
            return
        }
        pendingSpace = false
        guard !inline.isEmpty else { return }
        inline.append(0x0A)
    }

    /// Images without a description (`alt`, else `title`) are decorative or
    /// unknowable for a reader and emit nothing.
    private mutating func appendImage(_ node: WebHTMLNode) {
        var label = Self.collapsedText(node.attributes["alt"] ?? "")
        if label.isEmpty {
            label = Self.collapsedText(node.attributes["title"] ?? "")
        }
        guard !label.isEmpty else { return }
        switch format {
        case .markdown:
            if codeDepth == 0, let source = node.attributes["src"], let url = resourceURL(source) {
                appendInlineContent("![\(label)](\(url))")
            } else {
                appendInlineContent(label)
            }
        case .text:
            appendInlineContent("[image: \(label)]")
        }
    }

    private mutating func openWrapper(_ kind: WrapperKind) -> ExitAction {
        guard isMarkdown, codeDepth == 0 else { return .none }
        if kind != .code, wrappers.contains(where: { $0.kind == kind }) {
            return .none
        }
        if kind == .code {
            codeDepth += 1
        }
        wrappers.append(Wrapper(kind: kind))
        return .closeWrapper
    }

    private mutating func openLink(_ node: WebHTMLNode) -> ExitAction {
        guard let href = node.attributes["href"] else { return .none }
        collectLink(node, href: href)
        guard isMarkdown, includeLinks, codeDepth == 0, let target = linkTarget(href) else { return .none }
        // Same-page anchors (tables of contents, cite notes) lead nowhere new.
        if let pageURLKey, Self.withoutFragment(target) == pageURLKey {
            return .none
        }
        wrappers.append(Wrapper(kind: .link(target), rendersURLWhenEmpty: !node.children.contains(where: \.isElement)))
        return .closeWrapper
    }

    private mutating func closeWrapper() {
        guard let wrapper = wrappers.last else { return }
        if applied.count == wrappers.count {
            finalizeLastAppliedWrapper()
        } else if case .link(let url) = wrapper.kind, !wrapper.produced {
            // An anchor without any text renders its URL, unless its content
            // was markup that rendered nothing (an icon or decorative image).
            wrappers.removeLast()
            if wrapper.rendersURLWhenEmpty {
                appendInlineContent("<\(url)>")
            }
            return
        }
        if wrapper.kind == .code {
            codeDepth -= 1
        }
        wrappers.removeLast()
    }

    /// Closes the innermost wrapper applied to the current paragraph.
    private mutating func finalizeLastAppliedWrapper() {
        let wrapperIndex = applied.count - 1
        let start = applied.removeLast()
        var trailingBreaks = 0
        while inline.count > start, inline.last == 0x0A {
            inline.removeLast()
            trailingBreaks += 1
        }
        let kind = wrappers[wrapperIndex].kind
        if let marker = Self.marker(for: kind) {
            if inline.count == start {
                inline.removeLast(marker.count)
            } else {
                inline.append(contentsOf: marker)
            }
        } else {
            let content = Array(inline[start...])
            inline.removeSubrange(start...)
            if !content.isEmpty {
                switch kind {
                case .link(let url):
                    if String(decoding: content, as: UTF8.self) == url {
                        inline.append(contentsOf: "<\(url)>".utf8)
                    } else {
                        inline.append(Self.leftBracket)
                        inline.append(contentsOf: content)
                        inline.append(contentsOf: "](\(url))".utf8)
                    }
                default:
                    appendCodeSpan(content)
                }
            }
        }
        for _ in 0..<trailingBreaks {
            inline.append(0x0A)
        }
    }

    private mutating func appendCodeSpan(_ content: [UInt8]) {
        let content = content.map { $0 == 0x0A ? 0x20 : $0 }
        var longestRun = 0
        var run = 0
        for byte in content {
            run = byte == Self.backtick ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = [UInt8](repeating: Self.backtick, count: longestRun + 1)
        let padded = content.first == Self.backtick || content.last == Self.backtick
        inline.append(contentsOf: fence)
        if padded { inline.append(0x20) }
        inline.append(contentsOf: content)
        if padded { inline.append(0x20) }
        inline.append(contentsOf: fence)
    }

    // MARK: Blocks

    /// Ends the current paragraph (if any) as a block of `kind`.
    private mutating func flushInline(_ kind: BlockKind) {
        deferredFlush = false
        while !applied.isEmpty {
            finalizeLastAppliedWrapper()
        }
        pendingSpace = false
        guard !inline.isEmpty else { return }
        var lines: [String] = []
        inline.withUnsafeBufferPointer { buffer in
            var lineStart = 0
            for index in 0...buffer.count where index == buffer.count || buffer[index] == 0x0A {
                if index > lineStart {
                    lines.append(String(decoding: UnsafeBufferPointer(rebasing: buffer[lineStart..<index]), as: UTF8.self))
                } else if let last = lines.last, !last.isEmpty {
                    // Several <br> in a row: at most one blank line.
                    lines.append("")
                }
                lineStart = index + 1
            }
        }
        inline.removeAll(keepingCapacity: true)
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return }
        appendBlock(Block(lines: lines, kind: kind))
    }

    private mutating func appendBlock(_ block: Block) {
        guard !block.lines.isEmpty else { return }
        producedCount += 1
        frames[frames.count - 1].blocks.append(block)
    }

    private mutating func pushFrame(_ frame: Frame) -> ExitAction {
        flushInline(.flow)
        producedCount += 1
        frames.append(frame)
        return .popFrame
    }

    private mutating func popFrame() {
        guard frames.count > 1 else { return }
        if frames[frames.count - 1].kind == .preformatted {
            preDepth -= 1
        } else {
            flushInline(.flow)
        }
        let frame = frames.removeLast()
        let top = frames.count - 1
        switch frame.kind {
        case .root:
            break
        case .heading:
            let text = Self.joinedText(frame.blocks)
            guard !text.isEmpty else { return }
            let line = isMarkdown ? String(repeating: "#", count: frame.level) + " " + text : text
            appendBlock(Block(lines: [line], kind: .paragraph))
        case .summary, .term:
            let text = Self.joinedText(frame.blocks)
            guard !text.isEmpty else { return }
            let line = isMarkdown ? "**\(text)**" : text
            appendBlock(Block(lines: [line], kind: frame.kind == .term ? .term : .paragraph))
        case .blockquote:
            let lines = Self.compose(frame.blocks, style: .loose)
            appendBlock(Block(lines: Self.prefixed(lines, first: "> ", rest: "> "), kind: .paragraph))
        case .list:
            appendBlock(Block(lines: Self.compose(frame.blocks, style: .list), kind: .list))
        case .listItem:
            let lines = Self.compose(frame.blocks, style: .item)
            let indent = String(repeating: " ", count: frame.marker.count)
            appendBlock(Block(
                lines: Self.prefixed(lines, first: frame.marker, rest: indent),
                kind: .listItem,
                indent: frame.marker.count
            ))
        case .definitionList:
            appendBlock(Block(lines: Self.compose(frame.blocks, style: .definitionList), kind: .list))
        case .definition:
            let lines = Self.compose(frame.blocks, style: .item)
            appendBlock(Block(lines: Self.prefixed(lines, first: "  ", rest: "  "), kind: .definition))
        case .table:
            tableHeadDepth = frame.savedTableHeadDepth
            if !openTables.isEmpty {
                openTables.removeLast()
            }
            // Captions and stray (foster-parented) content precede the table.
            for block in frame.blocks {
                appendBlock(block)
            }
            appendBlock(Block(lines: tableLines(frame.rows), kind: .paragraph))
        case .row:
            guard frame.cells.contains(where: { !$0.isEmpty }) else { return }
            let isHeader = frame.inTableHead || frame.headerCellCount == frame.cells.count
            if frames[top].kind == .table {
                frames[top].rows.append(TableRow(cells: frame.cells, isHeader: isHeader))
            } else {
                appendBlock(Block(lines: [frame.cells.joined(separator: " | ")], kind: .flow))
            }
        case .cell:
            let text = Self.joinedText(frame.blocks)
            if frames[top].kind == .row {
                frames[top].cells.append(text)
                if frame.isHeaderCell {
                    frames[top].headerCellCount += 1
                }
            } else if !text.isEmpty {
                appendBlock(Block(lines: [text], kind: .flow))
            }
        case .preformatted:
            appendBlock(Block(lines: preformattedLines(language: frame.language), kind: .paragraph))
        }
    }

    private mutating func preformattedLines(language: String?) -> [String] {
        var bytes = preformatted
        preformatted.removeAll(keepingCapacity: true)
        // A newline right after <pre> is not content.
        if bytes.first == 0x0A {
            bytes.removeFirst()
        }
        while let last = bytes.last, last == 0x0A || last == 0x20 || last == 0x09 || last == 0x0C {
            bytes.removeLast()
        }
        var lines = String(decoding: bytes, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        lines = Array(lines.drop(while: { $0.allSatisfy { $0 == " " || $0 == "\t" } }))
        guard !lines.isEmpty else { return [] }
        guard isMarkdown else { return lines }

        var longestRun = 0
        var run = 0
        for byte in bytes {
            run = byte == Self.backtick ? run + 1 : 0
            longestRun = max(longestRun, run)
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return [fence + (language ?? "")] + lines + [fence]
    }

    private func tableLines(_ rows: [TableRow]) -> [String] {
        guard !rows.isEmpty else { return [] }
        guard isMarkdown else {
            return rows.map { $0.cells.joined(separator: " | ") }
        }
        // Markdown tables need exactly one header row, and it must be the first
        // one: a later all-<th> row is never relocated, document order is kept.
        let header = rows[0]
        let body = Array(rows.dropFirst())
        let columns = max(1, rows.map(\.cells.count).max() ?? 1)

        func line(_ cells: [String]) -> String {
            var escaped = cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }
            while escaped.count < columns {
                escaped.append("")
            }
            return "| " + escaped.joined(separator: " | ") + " |"
        }

        let separator = "|" + String(repeating: " --- |", count: columns)
        return [line(header.cells), separator] + body.map { line($0.cells) }
    }

    // MARK: Links and URLs

    private mutating func collectLink(_ node: WebHTMLNode, href: String) {
        guard includeLinks, links.count < maxLinks else { return }
        let cleaned = Self.cleanedURLString(href)
        guard !cleaned.isEmpty, !cleaned.hasPrefix("#"),
              let url = Self.resolve(cleaned, against: baseURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return
        }
        let absolute = url.absoluteString
        if let pageURLKey, Self.withoutFragment(absolute) == pageURLKey {
            return
        }
        guard !seenLinkURLs.contains(absolute) else { return }
        let text = Self.visibleText(of: node)
        guard text.count >= 3 else { return }
        seenLinkURLs.insert(absolute)
        links.append(WebExtractedLink(text: text, url: absolute))
    }

    /// Absolute URL for a rendered anchor, nil when it must render as text
    /// (`javascript:`, `mailto:`, unresolvable, other schemes).
    private func linkTarget(_ href: String) -> String? {
        guard let url = Self.resolve(href, against: baseURL),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme) else {
            return nil
        }
        return url.absoluteString
    }

    /// Absolute http(s) URL of an image source; `data:` and others are dropped.
    private func resourceURL(_ source: String) -> String? {
        guard let url = Self.resolve(source, against: baseURL),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        return url.absoluteString
    }

    static func resolve(_ raw: String, against base: URL?) -> URL? {
        let cleaned = cleanedURLString(raw)
        guard !cleaned.isEmpty, let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              url.scheme != nil else {
            return nil
        }
        return url
    }

    /// Strips leading/trailing whitespace and embedded tabs/newlines, as the
    /// URL standard does.
    static func cleanedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains(where: { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            value.removeAll { $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
        }
        return value
    }

    static func withoutFragment(_ url: String) -> String {
        guard let hash = url.firstIndex(of: "#") else { return url }
        return String(url[..<hash])
    }

    // MARK: Skipping

    static let skippedElements: Set<String> = [
        "script", "style", "noscript", "template", "svg", "canvas", "iframe", "object", "embed", "head",
        "input", "select", "textarea", "title",
    ]

    /// Dropped below a main-content root (and on a whole page).
    static let landmarkElements: Set<String> = ["nav", "footer", "aside"]
    static let landmarkRoles: Set<String> = [
        "navigation", "menu", "menubar", "complementary", "contentinfo", "dialog", "alert",
    ]
    /// Additionally dropped from a whole page: site headers and banners.
    static let pageLandmarkElements: Set<String> = landmarkElements.union(["header"])
    static let pageLandmarkRoles: Set<String> = landmarkRoles.union(["banner"])

    /// Roles of tables that are data tables whatever their shape.
    static let dataTableRoles: Set<String> = ["grid", "table"]

    /// Generic block containers: they end the current paragraph on both edges.
    static let blockElements: Set<String> = [
        "address", "article", "aside", "body", "caption", "center", "details", "dialog", "div", "fieldset",
        "figcaption", "figure", "footer", "form", "header", "hgroup", "html", "legend", "main", "nav",
        "search", "section", "tbody", "tfoot", "optgroup", "option", "frameset", "noframes", "listing",
        "xmp", "plaintext",
    ]

    /// Elements that separate words when measuring visible text.
    static let textBoundaryElements: Set<String> = blockElements.union([
        "br", "p", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "ul", "ol", "menu", "dir", "li", "dl",
        "dt", "dd", "table", "thead", "tr", "td", "th", "pre", "summary", "hr",
    ])

    static func isSkipped(_ node: WebHTMLNode, _ name: String) -> Bool {
        if skippedElements.contains(name) {
            return true
        }
        let attributes = node.attributes
        guard !attributes.isEmpty else { return false }
        if attributes["hidden"] != nil {
            return true
        }
        if let ariaHidden = attributes["aria-hidden"],
           ariaHidden.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true" {
            return true
        }
        if let style = attributes["style"], hidesByInlineStyle(style) {
            return true
        }
        return false
    }

    static func isLandmark(_ node: WebHTMLNode, _ name: String, mode: LandmarkMode) -> Bool {
        let elements: Set<String>
        let roles: Set<String>
        switch mode {
        case .keep:
            return false
        case .insideMainContent:
            elements = landmarkElements
            roles = landmarkRoles
        case .fullPage:
            elements = pageLandmarkElements
            roles = pageLandmarkRoles
        }
        if elements.contains(name) {
            return true
        }
        if let role = node.attributes["role"], tokens(role).contains(where: { roles.contains($0) }) {
            return true
        }
        return mode == .insideMainContent && name == "header" && containsNavigation(node)
    }

    /// Whether a subtree holds a `<nav>` or `[role=navigation]` element.
    private static func containsNavigation(_ root: WebHTMLNode) -> Bool {
        root.descendants.contains { node in
            guard case .element(let name) = node.kind else { return false }
            if name == "nav" {
                return true
            }
            return node.attributes["role"].map { tokens($0).contains("navigation") } ?? false
        }
    }

    /// A table is a data table when it says so (caption, th, thead, tfoot,
    /// a summary, a grid/table role) or when it is a plain, filled grid: no
    /// nested table, at least two rows and two columns, and fewer than a
    /// third of its cells empty. Anything else (a single row or column,
    /// tables nested for layout, sparse grids such as Hacker News' story
    /// list with its empty vote and indent cells) is a layout table whose
    /// rows render as ordinary blocks. Nested tables are not scanned: each
    /// one is classified on its own when the renderer reaches it, so the
    /// whole document is scanned in linear time.
    static func isDataTable(_ table: WebHTMLNode) -> Bool {
        if let summary = table.attributes["summary"], !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let role = table.attributes["role"], tokens(role).contains(where: { dataTableRoles.contains($0) }) {
            return true
        }
        var rows = 0
        var columns = 0
        var cells: [WebHTMLNode] = []
        var hasNestedTable = false
        var stack = table.children
        while let node = stack.popLast() {
            guard case .element(let name) = node.kind else { continue }
            switch name {
            case "caption", "th", "thead", "tfoot":
                return true
            case "table":
                hasNestedTable = true
                continue
            case "tr":
                rows += 1
                let rowCells = node.children.filter { $0.tagName == "td" }
                columns = max(columns, rowCells.count)
                cells.append(contentsOf: rowCells)
            default:
                break
            }
            stack.append(contentsOf: node.children)
        }
        guard !hasNestedTable, rows >= 2, columns >= 2 else { return false }
        let emptyCells = cells.count { !hasContent($0) }
        return emptyCells * 3 < cells.count
    }

    /// Visible text, or an image that renders (one with alt or title text).
    private static func hasContent(_ cell: WebHTMLNode) -> Bool {
        if !visibleText(of: cell).isEmpty {
            return true
        }
        return cell.descendants.contains { node in
            guard node.tagName == "img" else { return false }
            let label = (node.attributes["alt"] ?? "") + (node.attributes["title"] ?? "")
            return !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// `display:none` / `visibility:hidden` in an inline style, ignoring case
    /// and whitespace.
    static func hidesByInlineStyle(_ style: String) -> Bool {
        var compact: [UInt8] = []
        compact.reserveCapacity(style.utf8.count)
        for byte in style.utf8 where !isHTMLWhitespace(byte) {
            compact.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
        }
        return contains(compact, Array("display:none".utf8)) || contains(compact, Array("visibility:hidden".utf8))
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        outer: for start in 0...(haystack.count - needle.count) {
            for offset in 0..<needle.count where haystack[start + offset] != needle[offset] {
                continue outer
            }
            return true
        }
        return false
    }

    static func tokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { $0.isASCII && $0.isWhitespace }).map(String.init)
    }

    static func codeLanguage(of node: WebHTMLNode) -> String? {
        for name in node.classList {
            let lowered = name.lowercased()
            for prefix in ["language-", "lang-"] where lowered.hasPrefix(prefix) {
                let language = String(name.dropFirst(prefix.count))
                if !language.isEmpty {
                    return language
                }
            }
        }
        return nil
    }

    // MARK: Text helpers

    static let ampersand = UInt8(ascii: "&")
    static let backtick = UInt8(ascii: "`")
    static let leftBracket = UInt8(ascii: "[")

    @inline(__always)
    static func isHTMLWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D || byte == 0x0C
    }

    /// Byte width of the collapsible whitespace at `index`: ASCII HTML
    /// whitespace or U+00A0 (no-break space), else 0.
    @inline(__always)
    static func whitespaceWidth(_ buffer: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        let byte = buffer[index]
        if isHTMLWhitespace(byte) {
            return 1
        }
        if byte == 0xC2, index + 1 < buffer.count, buffer[index + 1] == 0xA0 {
            return 2
        }
        return 0
    }

    static func marker(for kind: WrapperKind) -> [UInt8]? {
        switch kind {
        case .strong: Array("**".utf8)
        case .emphasis: Array("*".utf8)
        case .strikethrough: Array("~~".utf8)
        case .code, .link: nil
        }
    }

    /// Collapses whitespace of already-decoded text.
    static func collapsedText(_ text: String) -> String {
        var output: [UInt8] = []
        var pendingSpace = false
        var copy = text
        copy.withUTF8 { appendCollapsedBytes($0, to: &output, pendingSpace: &pendingSpace) }
        return String(decoding: output, as: UTF8.self)
    }

    /// Decodes character references in raw text, then collapses whitespace.
    static func collapsedText(decoding raw: String) -> String {
        collapsedText(WebHTMLEntities.decode(raw))
    }

    private static func appendCollapsedBytes(
        _ buffer: UnsafeBufferPointer<UInt8>,
        to output: inout [UInt8],
        pendingSpace: inout Bool
    ) {
        let count = buffer.count
        var index = 0
        while index < count {
            let width = whitespaceWidth(buffer, at: index)
            if width > 0 {
                pendingSpace = true
                index += width
                continue
            }
            if pendingSpace, !output.isEmpty {
                output.append(0x20)
            }
            pendingSpace = false
            output.append(buffer[index])
            index += 1
        }
    }

    /// Visible text of a subtree (skip rules applied, entities decoded,
    /// whitespace collapsed, block boundaries separate words). Iterative.
    static func visibleText(of root: WebHTMLNode) -> String {
        var output: [UInt8] = []
        var pendingSpace = false
        var stack: [WebHTMLNode?] = [root]
        while let entry = stack.popLast() {
            guard let node = entry else {
                pendingSpace = true
                continue
            }
            switch node.kind {
            case .text(let raw):
                var text = raw
                text.withUTF8 { buffer in
                    guard buffer.contains(ampersand) else {
                        appendCollapsedBytes(buffer, to: &output, pendingSpace: &pendingSpace)
                        return
                    }
                    var decoded: [UInt8] = []
                    WebHTMLEntities.appendDecoded(buffer, to: &decoded)
                    decoded.withUnsafeBufferPointer {
                        appendCollapsedBytes($0, to: &output, pendingSpace: &pendingSpace)
                    }
                }
            case .element(let name):
                guard !isSkipped(node, name) else { continue }
                if textBoundaryElements.contains(name) {
                    pendingSpace = true
                    stack.append(nil)
                }
                for child in node.children.reversed() {
                    stack.append(child)
                }
            case .document:
                for child in node.children.reversed() {
                    stack.append(child)
                }
            case .comment:
                continue
            }
        }
        return String(decoding: output, as: UTF8.self)
    }

    /// One-line text of a collapse frame's blocks.
    private static func joinedText(_ blocks: [Block]) -> String {
        let joined = blocks
            .flatMap(\.lines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedText(joined)
    }

    // MARK: Composition

    enum ComposeStyle {
        /// Blank line between blocks (root, blockquote).
        case loose
        /// List item / definition content: tight unless a paragraph-like block.
        case item
        /// List frame: items stacked; stray blocks indented under the last item.
        case list
        /// Definition list: blank line before each new group of terms.
        case definitionList
    }

    static func compose(_ blocks: [Block], style: ComposeStyle) -> [String] {
        var lines: [String] = []
        var previous: BlockKind?
        var itemIndent: Int?
        for block in blocks where !block.lines.isEmpty {
            if let previous {
                let tight: Bool
                switch style {
                case .loose:
                    tight = (previous == .listItem && block.kind == .listItem)
                        || (block.kind == .definition && (previous == .term || previous == .definition))
                case .item:
                    tight = previous != .paragraph && block.kind != .paragraph
                case .list:
                    tight = true
                case .definitionList:
                    tight = block.kind != .term || previous == .term
                }
                if !tight {
                    lines.append("")
                }
            }
            if style == .list, block.kind != .listItem, let itemIndent {
                let indent = String(repeating: " ", count: itemIndent)
                lines.append(contentsOf: block.lines.map { $0.isEmpty ? $0 : indent + $0 })
            } else {
                lines.append(contentsOf: block.lines)
            }
            if block.kind == .listItem {
                itemIndent = block.indent
            }
            previous = block.kind
        }
        return lines
    }

    static func prefixed(_ lines: [String], first: String, rest: String) -> [String] {
        var result: [String] = []
        result.reserveCapacity(lines.count)
        for (index, line) in lines.enumerated() {
            let prefix = index == 0 ? first : rest
            if line.isEmpty {
                var trimmed = prefix
                while trimmed.last == " " {
                    trimmed.removeLast()
                }
                result.append(trimmed)
            } else {
                result.append(prefix + line)
            }
        }
        return result
    }
}
