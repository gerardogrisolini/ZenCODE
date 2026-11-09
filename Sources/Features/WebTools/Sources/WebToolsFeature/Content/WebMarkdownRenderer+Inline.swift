extension WebMarkdownRenderer {
    // MARK: Inline content

    mutating func appendText(_ raw: String) {
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

    mutating func lineBreak() {
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
    mutating func appendImage(_ node: WebHTMLNode) {
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

    mutating func openWrapper(_ kind: WrapperKind) -> ExitAction {
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

    mutating func openLink(_ node: WebHTMLNode) -> ExitAction {
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

    mutating func closeWrapper() {
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
    mutating func finalizeLastAppliedWrapper() {
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
}
