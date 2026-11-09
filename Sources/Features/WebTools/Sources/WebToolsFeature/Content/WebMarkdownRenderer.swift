import Foundation

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
    let pageURLKey: String?
    private(set) var links: [WebExtractedLink] = []
    private var seenLinkURLs: Set<String> = []

    var frames: [Frame] = [Frame(kind: .root)]
    /// Inline content of the paragraph being built in the top frame.
    var inline: [UInt8] = []
    var pendingSpace = false
    /// Open inline wrappers (outermost first) and, for the current paragraph,
    /// the content start offset of each wrapper applied so far (a prefix).
    var wrappers: [Wrapper] = []
    var applied: [Int] = []
    var preformatted: [UInt8] = []
    var preDepth = 0
    var codeDepth = 0
    var tableHeadDepth = 0
    /// One entry per open table, innermost last.
    var openTables: [OpenTable] = []
    /// Inside layout cells a block boundary is deferred: the text before a
    /// block is ended only once the block produces content, so empty
    /// decorative blocks (icons, spacers) do not split a row.
    var deferredFlush = false
    /// Incremented whenever inline content, a block or a frame is produced.
    var producedCount = 0

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

    var isMarkdown: Bool {
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

    // MARK: Link collection

    mutating func collectLink(_ node: WebHTMLNode, href: String) {
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
}
