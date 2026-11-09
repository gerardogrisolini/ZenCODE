import Foundation

struct WebHTMLMetadata: Sendable, Equatable {
    /// `<title>` collapsed, else the first `<h1>`, else "".
    let title: String
    let description: String?
}

// MARK: - Document survey

/// One iterative pass collecting head metadata and main-content candidates.
struct WebDocumentSurvey {
    var title: String?
    var firstHeading: WebHTMLNode?
    var description: String?
    var ogDescription: String?
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

    func metadata() -> WebHTMLMetadata {
        var title = self.title ?? ""
        if title.isEmpty, let heading = firstHeading {
            title = WebMarkdownRenderer.visibleText(of: heading)
        }
        return WebHTMLMetadata(title: title, description: description ?? ogDescription)
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
