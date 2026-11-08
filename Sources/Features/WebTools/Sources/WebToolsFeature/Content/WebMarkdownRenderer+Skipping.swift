import Foundation

extension WebMarkdownRenderer {
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
}
