extension WebMarkdownRenderer {
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
    static func joinedText(_ blocks: [Block]) -> String {
        let joined = blocks
            .flatMap(\.lines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsedText(joined)
    }
}
