extension HTMLParseState {
    // MARK: Tree construction

    mutating func flushText(upTo end: Int) {
        guard let start = textStart else { return }
        textStart = nil
        guard end > start else { return }
        let text = slice(start..<end)
        if openNames.last == "head" || openNames.last == "html", text.contains(where: { !Byte.isWhitespace($0) }) {
            // Character data cannot live in <head>: it implies </head>, and
            // directly under <html> it implies <body>.
            if openNames.last == "head" {
                popTo(openNodes.count - 1)
            }
            if openNames.last == "html" {
                insertImplicitBody()
            }
        }
        appendNode(WebHTMLNode(kind: .text(String(decoding: text, as: UTF8.self))))
    }

    mutating func appendRawText(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        appendNode(WebHTMLNode(kind: .text(String(decoding: slice(range), as: UTF8.self))))
    }

    /// Appends a non-element node to the current node.
    mutating func appendNode(_ node: WebHTMLNode) {
        openNodes[openNodes.count - 1].appendChild(node)
    }

    mutating func handleStartTag(
        _ name: String,
        attributes: [String: String],
        selfClosing: Bool,
        contentStart: Int
    ) -> Int {
        switch name {
        case "html", "body":
            if let index = positions[name]?.last {
                mergeAttributes(attributes, into: openNodes[index])
                return contentStart
            }
        case "head":
            if positions["head"]?.isEmpty == false || positions["body"]?.isEmpty == false {
                return contentStart
            }
        default:
            break
        }
        if openNames.last == "head", !WebHTMLElementSets.headContentElements.contains(name) {
            popTo(openNodes.count - 1)
        }
        // Body content directly under <html> implies <body>, so content that
        // precedes an explicit (or missing) <body> tag is not lost.
        if openNames.last == "html", name != "body", name != "head", name != "frameset",
           !WebHTMLElementSets.headContentElements.contains(name) {
            insertImplicitBody()
        }

        closeImpliedElements(before: name)

        let node = WebHTMLNode(kind: .element(name), attributes: attributes)
        let depth = attachElement(node)
        // `/>` is honoured only on void elements and in foreign content (svg,
        // math); on HTML elements such as <div/> or <a href=x />, it is ignored.
        let isForeign = name == "svg" || name == "math"
            || positions["svg"]?.isEmpty == false || positions["math"]?.isEmpty == false
        guard !(selfClosing && isForeign), !WebHTMLElementSets.voidElements.contains(name) else {
            return contentStart
        }
        push(node, name: name, depth: depth)
        guard WebHTMLElementSets.rawTextElements.contains(name) else { return contentStart }
        return consumeRawText(of: name, from: contentStart)
    }

    mutating func handleEndTag(_ name: String) {
        // </body> and </html> are ignored so trailing content stays in the
        // body, and end tags of void elements carry no structure.
        if name == "body" || name == "html" || WebHTMLElementSets.voidElements.contains(name) {
            return
        }
        guard let index = positions[name]?.last, index > 0 else { return }
        let boundaries: [String]
        switch name {
        case "td", "th", "tr", "thead", "tbody", "tfoot", "caption":
            boundaries = WebHTMLElementSets.tableScope
        case "table":
            boundaries = ["template", "html"]
        case "li":
            boundaries = WebHTMLElementSets.listItemScope
        case "p":
            boundaries = WebHTMLElementSets.buttonScope
        default:
            boundaries = WebHTMLElementSets.genericScope
        }
        guard index > nearestIndex(of: boundaries, excluding: name) else { return }
        popTo(index)
    }

    private mutating func closeImpliedElements(before name: String) {
        if WebHTMLElementSets.paragraphClosers.contains(name),
           let paragraph = positions["p"]?.last,
           paragraph > nearestIndex(of: WebHTMLElementSets.buttonScope, excluding: "p") {
            popTo(paragraph)
        }

        switch name {
        case "li":
            closeNearestListItem(matching: ["li"])
        case "dd", "dt":
            closeNearestListItem(matching: ["dd", "dt"])
        case "option", "optgroup":
            if openNames.last == "option" { popTo(openNodes.count - 1) }
        case "tr":
            closeTableParts(["tr", "td", "th"])
        case "td", "th":
            closeTableParts(["td", "th"])
        case "thead", "tbody", "tfoot":
            closeTableParts(["thead", "tbody", "tfoot", "tr", "td", "th"])
        case "h1", "h2", "h3", "h4", "h5", "h6":
            if let current = openNames.last, WebHTMLElementSets.headingElements.contains(current) {
                popTo(openNodes.count - 1)
            }
        case "a":
            // Anchors never nest: an unclosed <a> ends where the next starts.
            if let anchor = positions["a"]?.last,
               anchor > nearestIndex(of: WebHTMLElementSets.genericScope, excluding: "a") {
                popTo(anchor)
            }
        default:
            break
        }
    }

    /// WHATWG `li`/`dd`/`dt` rule: walk down from the current node; close the
    /// first matching item unless a special element (other than address, div
    /// or p) is reached first.
    private mutating func closeNearestListItem(matching names: [String]) {
        guard let nearest = stopPositions.last, names.contains(openNames[nearest]) else { return }
        popTo(nearest)
    }

    /// Closes the outermost open element named in `names` that sits above the
    /// nearest open `<table>` (or anywhere when no table is open).
    private mutating func closeTableParts(_ names: [String]) {
        let table = positions["table"]?.last ?? 0
        var lowest: Int?
        for name in names {
            guard let stack = positions[name] else { continue }
            for position in stack.reversed() {
                if position <= table { break }
                lowest = min(lowest ?? position, position)
            }
        }
        if let lowest {
            popTo(lowest)
        }
    }

    private func nearestIndex(of names: [String], excluding excluded: String) -> Int {
        var nearest = 0
        for name in names where name != excluded {
            if let position = positions[name]?.last, position > nearest {
                nearest = position
            }
        }
        return nearest
    }

    private mutating func insertImplicitBody() {
        let body = WebHTMLNode(kind: .element("body"))
        let depth = attachElement(body)
        push(body, name: "body", depth: depth)
    }

    private func mergeAttributes(_ attributes: [String: String], into node: WebHTMLNode) {
        for (name, value) in attributes where node.attributes[name] == nil {
            node.attributes[name] = value
        }
    }

    /// Attaches `node` to the current node, or to its parent once the DOM
    /// depth cap is reached, and returns the node's DOM depth.
    private mutating func attachElement(_ node: WebHTMLNode) -> Int {
        let top = openNodes.count - 1
        var parent = openNodes[top]
        var depth = openDepths[top] + 1
        if depth > WebHTMLParser.maximumTreeDepth, let grandparent = parent.parent {
            parent = grandparent
            depth -= 1
        }
        parent.appendChild(node)
        return depth
    }

    private mutating func push(_ node: WebHTMLNode, name: String, depth: Int) {
        let index = openNodes.count
        openNodes.append(node)
        openNames.append(name)
        openDepths.append(depth)
        positions[name, default: []].append(index)
        if WebHTMLElementSets.listItemStopElements.contains(name) {
            stopPositions.append(index)
        }
    }

    /// Pops open elements until the stack has `index` entries; the document
    /// at position 0 is never popped.
    mutating func popTo(_ index: Int) {
        let target = max(1, index)
        while openNodes.count > target {
            let name = openNames.removeLast()
            openNodes.removeLast()
            openDepths.removeLast()
            positions[name]?.removeLast()
            if WebHTMLElementSets.listItemStopElements.contains(name) {
                stopPositions.removeLast()
            }
        }
    }
}
