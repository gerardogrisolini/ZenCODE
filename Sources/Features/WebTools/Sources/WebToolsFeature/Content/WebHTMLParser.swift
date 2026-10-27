import Foundation

/// Tolerant, single-pass HTML parser producing a ``WebHTMLNode`` tree.
///
/// It is a hand-rolled byte-level tokenizer over the UTF-8 input plus a
/// simplified tree builder. It is not a full WHATWG implementation, but it
/// covers the constructs that matter for content extraction: doctype,
/// comments, CDATA, processing instructions, quoted/unquoted/valueless
/// attributes, void elements (`/>` is honoured only on those and in svg/math
/// content, as in HTML), raw-text elements, the common
/// implied end tags and scoped end-tag matching. Work per tag is constant
/// (open-element positions are indexed by name), so parsing is linear in the
/// input size and never recurses. It never fails: junk is ignored or kept as
/// text.
enum WebHTMLParser {
    /// Input beyond this many UTF-8 bytes is dropped before parsing.
    static let defaultMaxInputBytes = 8 * 1024 * 1024
    /// Maximum DOM depth. Like Blink, deeper elements are attached to the
    /// parent of the deepest allowed node, so consumers never see a tree
    /// deeper than this however malicious the input is.
    static let maximumTreeDepth = 512

    static func parse(_ html: String, maxInputBytes: Int = defaultMaxInputBytes) -> WebHTMLNode {
        let limit = max(0, maxInputBytes)
        let utf8 = html.utf8
        let bytes: [UInt8] = utf8.count > limit ? Array(utf8.prefix(limit)) : Array(utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            var state = HTMLParseState(bytes: buffer)
            state.run()
            return state.document
        }
    }
}

// MARK: - Element categories

enum WebHTMLElementSets {
    static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Elements whose content is consumed verbatim until the matching end tag.
    static let rawTextElements: Set<String> = [
        "script", "style", "textarea", "title", "noscript", "xmp", "iframe", "noembed", "noframes",
    ]

    /// Start tags that implicitly close an open `<p>` in button scope.
    static let paragraphClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl",
        "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header",
        "hgroup", "hr", "main", "menu", "nav", "ol", "p", "pre", "section", "summary", "table", "ul", "li",
        "dd", "dt", "listing", "plaintext", "xmp", "search",
    ]

    /// WHATWG "special" elements except `address`, `div` and `p`: the open
    /// elements at which the implied `li`/`dd`/`dt` end-tag search stops.
    static let listItemStopElements: Set<String> = [
        "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
        "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "dl", "dt", "embed",
        "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4",
        "h5", "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link",
        "listing", "main", "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol",
        "param", "plaintext", "pre", "script", "search", "section", "select", "source", "style", "summary",
        "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul",
        "wbr", "xmp",
    ]

    /// Elements that may stay inside `<head>`; any other start tag closes it.
    static let headContentElements: Set<String> = [
        "base", "basefont", "bgsound", "link", "meta", "title", "noscript", "script", "style", "template",
    ]

    static let headingElements: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]

    static let genericScope = ["td", "th", "caption", "table", "template", "html", "marquee", "object", "applet"]
    static let buttonScope = genericScope + ["button"]
    static let listItemScope = genericScope + ["ul", "ol"]
    static let tableScope = ["table", "template", "html"]
}

// MARK: - Parser state

private enum Byte {
    static let lessThan = UInt8(ascii: "<")
    static let greaterThan = UInt8(ascii: ">")
    static let slash = UInt8(ascii: "/")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let equals = UInt8(ascii: "=")
    static let doubleQuote = UInt8(ascii: "\"")
    static let singleQuote = UInt8(ascii: "'")
    static let dash = UInt8(ascii: "-")
    static let rightBracket = UInt8(ascii: "]")
    static let ampersand = UInt8(ascii: "&")

    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D || byte == 0x0C
    }

    @inline(__always)
    static func isAlpha(_ byte: UInt8) -> Bool {
        (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
    }

    @inline(__always)
    static func isUpper(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")
    }

    @inline(__always)
    static func isTagNameEnd(_ byte: UInt8) -> Bool {
        isWhitespace(byte) || byte == slash || byte == greaterThan
    }
}

private struct HTMLParseState {
    let bytes: UnsafeBufferPointer<UInt8>
    let document: WebHTMLNode
    private var openNodes: [WebHTMLNode]
    private var openNames: [String]
    private var openDepths: [Int]
    /// Stack positions of every open element, indexed by tag name.
    private var positions: [String: [Int]] = [:]
    /// Stack positions of open `listItemStopElements`.
    private var stopPositions: [Int] = []
    private var textStart: Int?

    init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
        let document = WebHTMLNode(kind: .document)
        self.document = document
        openNodes = [document]
        openNames = [""]
        openDepths = [0]
    }

    mutating func run() {
        let count = bytes.count
        var index = 0
        while index < count {
            guard bytes[index] == Byte.lessThan else {
                if textStart == nil { textStart = index }
                index = indexOf(Byte.lessThan, from: index + 1) ?? count
                continue
            }
            let next: UInt8 = index + 1 < count ? bytes[index + 1] : 0
            if Byte.isAlpha(next) {
                flushText(upTo: index)
                index = parseStartTag(at: index)
            } else if next == Byte.slash {
                let after: UInt8 = index + 2 < count ? bytes[index + 2] : 0
                if Byte.isAlpha(after) {
                    flushText(upTo: index)
                    index = parseEndTag(at: index)
                } else if index + 2 >= count {
                    // A trailing "</" is plain text.
                    if textStart == nil { textStart = index }
                    index = count
                } else {
                    // "</>" is dropped; "</ junk>" is a bogus comment.
                    flushText(upTo: index)
                    index = skipPast(Byte.greaterThan, from: index + 2)
                }
            } else if next == Byte.bang {
                flushText(upTo: index)
                index = parseMarkupDeclaration(at: index)
            } else if next == Byte.question {
                // Processing instruction / XML declaration: bogus comment.
                flushText(upTo: index)
                index = skipPast(Byte.greaterThan, from: index + 2)
            } else {
                // A literal "<" that does not start markup.
                if textStart == nil { textStart = index }
                index += 1
            }
        }
        flushText(upTo: count)
    }

    // MARK: Tokenizer

    private func indexOf(_ byte: UInt8, from start: Int) -> Int? {
        var index = start
        let count = bytes.count
        while index < count {
            if bytes[index] == byte { return index }
            index += 1
        }
        return nil
    }

    private func skipPast(_ byte: UInt8, from start: Int) -> Int {
        guard let index = indexOf(byte, from: start) else { return bytes.count }
        return index + 1
    }

    private func hasPrefix(_ prefix: StaticString, at index: Int) -> Bool {
        let length = prefix.utf8CodeUnitCount
        guard index + length <= bytes.count else { return false }
        return prefix.withUTF8Buffer { expected in
            for offset in 0..<length where bytes[index + offset] != expected[offset] {
                return false
            }
            return true
        }
    }

    /// Index of the first byte of `a b c` at or after `start`.
    private func indexOf(_ first: UInt8, _ second: UInt8, _ third: UInt8, from start: Int) -> Int? {
        var index = start
        let count = bytes.count
        while index + 2 < count {
            guard let candidate = indexOf(first, from: index), candidate + 2 < count else { return nil }
            if bytes[candidate + 1] == second, bytes[candidate + 2] == third {
                return candidate
            }
            index = candidate + 1
        }
        return nil
    }

    private func slice(_ range: Range<Int>) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: bytes[range])
    }

    private func lowercasedString(_ range: Range<Int>) -> String {
        let source = slice(range)
        guard source.contains(where: Byte.isUpper) else {
            return String(decoding: source, as: UTF8.self)
        }
        return String(decoding: source.map { Byte.isUpper($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
    }

    private mutating func parseMarkupDeclaration(at index: Int) -> Int {
        let count = bytes.count
        if hasPrefix("<!--", at: index) {
            let bodyStart = index + 4
            // "<!-->" and "<!--->" are complete (empty) comments.
            if bodyStart < count, bytes[bodyStart] == Byte.greaterThan {
                appendNode(WebHTMLNode(kind: .comment))
                return bodyStart + 1
            }
            if bodyStart + 1 < count, bytes[bodyStart] == Byte.dash, bytes[bodyStart + 1] == Byte.greaterThan {
                appendNode(WebHTMLNode(kind: .comment))
                return bodyStart + 2
            }
            appendNode(WebHTMLNode(kind: .comment))
            guard let end = indexOf(Byte.dash, Byte.dash, Byte.greaterThan, from: bodyStart) else { return count }
            return end + 3
        }
        if hasPrefix("<![CDATA[", at: index) {
            let contentStart = index + 9
            let end = indexOf(Byte.rightBracket, Byte.rightBracket, Byte.greaterThan, from: contentStart) ?? count
            if end > contentStart {
                // Text nodes hold raw text that the converter entity-decodes,
                // so escape "&" to keep CDATA content literal.
                let raw = String(decoding: slice(contentStart..<end), as: UTF8.self)
                let text = raw.contains("&") ? raw.replacingOccurrences(of: "&", with: "&amp;") : raw
                appendNode(WebHTMLNode(kind: .text(text)))
            }
            return min(count, end + 3)
        }
        // Doctype or bogus comment.
        return skipPast(Byte.greaterThan, from: index + 2)
    }

    private mutating func parseStartTag(at index: Int) -> Int {
        let count = bytes.count
        var cursor = index + 1
        let nameStart = cursor
        while cursor < count, !Byte.isTagNameEnd(bytes[cursor]) {
            cursor += 1
        }
        let name = lowercasedString(nameStart..<cursor)
        var attributes: [String: String] = [:]
        var selfClosing = false

        while true {
            while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                cursor += 1
            }
            // EOF inside a tag: the tag is dropped, as browsers do.
            guard cursor < count else { return count }
            let byte = bytes[cursor]
            if byte == Byte.greaterThan {
                cursor += 1
                break
            }
            if byte == Byte.slash {
                if cursor + 1 < count, bytes[cursor + 1] == Byte.greaterThan {
                    selfClosing = true
                    cursor += 2
                    break
                }
                cursor += 1
                continue
            }

            let attributeStart = cursor
            cursor += 1
            while cursor < count {
                let current = bytes[cursor]
                if Byte.isTagNameEnd(current) || current == Byte.equals { break }
                cursor += 1
            }
            let attributeName = lowercasedString(attributeStart..<cursor)
            while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                cursor += 1
            }

            var value = ""
            if cursor < count, bytes[cursor] == Byte.equals {
                cursor += 1
                while cursor < count, Byte.isWhitespace(bytes[cursor]) {
                    cursor += 1
                }
                if cursor < count, bytes[cursor] == Byte.doubleQuote || bytes[cursor] == Byte.singleQuote {
                    let quote = bytes[cursor]
                    let valueStart = cursor + 1
                    guard let close = indexOf(quote, from: valueStart) else { return count }
                    value = WebHTMLEntities.decodedString(slice(valueStart..<close))
                    cursor = close + 1
                } else {
                    let valueStart = cursor
                    while cursor < count, !Byte.isWhitespace(bytes[cursor]), bytes[cursor] != Byte.greaterThan {
                        cursor += 1
                    }
                    value = WebHTMLEntities.decodedString(slice(valueStart..<cursor))
                }
            }
            // The first occurrence of a duplicated attribute wins.
            if attributes[attributeName] == nil {
                attributes[attributeName] = value
            }
        }

        return handleStartTag(name, attributes: attributes, selfClosing: selfClosing, contentStart: cursor)
    }

    private mutating func parseEndTag(at index: Int) -> Int {
        let count = bytes.count
        var cursor = index + 2
        let nameStart = cursor
        while cursor < count, !Byte.isTagNameEnd(bytes[cursor]) {
            cursor += 1
        }
        let name = lowercasedString(nameStart..<cursor)
        let end = skipPast(Byte.greaterThan, from: cursor)
        handleEndTag(name)
        return end
    }

    /// Consumes raw text up to the matching end tag (case-insensitive) and
    /// closes the raw-text element.
    private mutating func consumeRawText(of name: String, from start: Int) -> Int {
        let count = bytes.count
        let nameBytes = Array(name.utf8)
        var cursor = start
        while let lessThan = indexOf(Byte.lessThan, from: cursor) {
            let nameStart = lessThan + 2
            let nameEnd = nameStart + nameBytes.count
            if lessThan + 1 < count, bytes[lessThan + 1] == Byte.slash, nameEnd <= count,
               matchesLowercased(nameBytes, at: nameStart),
               nameEnd == count || Byte.isTagNameEnd(bytes[nameEnd]) {
                appendRawText(start..<lessThan)
                popTo(openNodes.count - 1)
                return skipPast(Byte.greaterThan, from: nameEnd)
            }
            cursor = lessThan + 1
        }
        appendRawText(start..<count)
        popTo(openNodes.count - 1)
        return count
    }

    private func matchesLowercased(_ name: [UInt8], at index: Int) -> Bool {
        for offset in 0..<name.count {
            let byte = bytes[index + offset]
            if (Byte.isUpper(byte) ? byte | 0x20 : byte) != name[offset] { return false }
        }
        return true
    }

    // MARK: Tree construction

    private mutating func flushText(upTo end: Int) {
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

    private mutating func appendRawText(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        appendNode(WebHTMLNode(kind: .text(String(decoding: slice(range), as: UTF8.self))))
    }

    /// Appends a non-element node to the current node.
    private mutating func appendNode(_ node: WebHTMLNode) {
        openNodes[openNodes.count - 1].appendChild(node)
    }

    private mutating func handleStartTag(
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

    private mutating func handleEndTag(_ name: String) {
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
    private mutating func popTo(_ index: Int) {
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

// MARK: - Character references

/// Single-pass, byte-level HTML character reference decoder (no regular
/// expressions). Named references require the trailing `;`; numeric ones
/// accept a missing `;` like browsers do.
enum WebHTMLEntities {
    /// `keepingInvalidNumericReferences` leaves numeric references that are not
    /// meaningful text (NUL, surrogates, out-of-range values, control
    /// characters) as written instead of applying the WHATWG replacement.
    static func decode(_ text: String, keepingInvalidNumericReferences: Bool = false) -> String {
        guard text.utf8.contains(Byte.ampersand) else { return text }
        var copy = text
        return copy.withUTF8 { decodedString($0, keepingInvalidNumericReferences: keepingInvalidNumericReferences) }
    }

    static func decodedString(
        _ input: UnsafeBufferPointer<UInt8>,
        keepingInvalidNumericReferences: Bool = false
    ) -> String {
        guard input.contains(Byte.ampersand) else {
            return String(decoding: input, as: UTF8.self)
        }
        var output: [UInt8] = []
        output.reserveCapacity(input.count)
        appendDecoded(input, to: &output, keepingInvalidNumericReferences: keepingInvalidNumericReferences)
        return String(decoding: output, as: UTF8.self)
    }

    static func appendDecoded(
        _ input: UnsafeBufferPointer<UInt8>,
        to output: inout [UInt8],
        keepingInvalidNumericReferences: Bool = false
    ) {
        let count = input.count
        var index = 0
        var runStart = 0
        while index < count {
            guard input[index] == Byte.ampersand,
                  let reference = parseReference(
                      input, at: index, keepingInvalidNumericReferences: keepingInvalidNumericReferences
                  ) else {
                index += 1
                continue
            }
            if index > runStart {
                output.append(contentsOf: UnsafeBufferPointer(rebasing: input[runStart..<index]))
            }
            if let scalar = reference.scalar {
                appendUTF8(scalar, to: &output)
            }
            index = reference.end
            runStart = index
        }
        if count > runStart {
            output.append(contentsOf: UnsafeBufferPointer(rebasing: input[runStart..<count]))
        }
    }

    /// Returns the decoded scalar (nil when the reference decodes to nothing)
    /// and the index after the reference, or nil when `&` starts no reference.
    private static func parseReference(
        _ input: UnsafeBufferPointer<UInt8>,
        at index: Int,
        keepingInvalidNumericReferences: Bool
    ) -> (scalar: UInt32?, end: Int)? {
        let count = input.count
        var cursor = index + 1
        guard cursor < count else { return nil }

        if input[cursor] == UInt8(ascii: "#") {
            cursor += 1
            var hexadecimal = false
            if cursor < count, input[cursor] | 0x20 == UInt8(ascii: "x") {
                hexadecimal = true
                cursor += 1
            }
            let digitsStart = cursor
            var value: UInt32 = 0
            while cursor < count, let digit = digitValue(input[cursor], hexadecimal: hexadecimal) {
                if value <= 0x10FFFF {
                    value = value * (hexadecimal ? 16 : 10) + digit
                }
                cursor += 1
            }
            guard cursor > digitsStart else { return nil }
            if cursor < count, input[cursor] == UInt8(ascii: ";") {
                cursor += 1
            }
            let scalar = numericScalar(value)
            if keepingInvalidNumericReferences, scalar == nil || (scalar == 0xFFFD && value != 0xFFFD) {
                return nil
            }
            return (scalar, cursor)
        }

        let nameStart = cursor
        while cursor < count, cursor - nameStart < 32, isAlphanumeric(input[cursor]) {
            cursor += 1
        }
        guard cursor > nameStart, cursor < count, input[cursor] == UInt8(ascii: ";") else { return nil }
        let name = String(decoding: UnsafeBufferPointer(rebasing: input[nameStart..<cursor]), as: UTF8.self)
        guard let value = namedEntities[name] else { return nil }
        return (value, cursor + 1)
    }

    private static func digitValue(_ byte: UInt8, hexadecimal: Bool) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f") where hexadecimal:
            return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F") where hexadecimal:
            return UInt32(byte - UInt8(ascii: "A") + 10)
        default:
            return nil
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        Byte.isAlpha(byte) || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    /// WHATWG numeric reference fix-ups; C0 controls (other than whitespace)
    /// decode to nothing because they are never meaningful page text.
    private static func numericScalar(_ value: UInt32) -> UInt32? {
        switch value {
        case 0, 0xD800...0xDFFF, 0x110000...:
            return 0xFFFD
        case 0x09, 0x0A, 0x0C, 0x0D:
            return value
        case 0x01...0x1F, 0x7F:
            return nil
        case 0x80...0x9F:
            return windows1252[value]
        default:
            return value
        }
    }

    private static func appendUTF8(_ value: UInt32, to output: inout [UInt8]) {
        switch value {
        case 0..<0x80:
            output.append(UInt8(value))
        case 0x80..<0x800:
            output.append(UInt8(0xC0 | (value >> 6)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        case 0x800..<0x10000:
            output.append(UInt8(0xE0 | (value >> 12)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        default:
            output.append(UInt8(0xF0 | (value >> 18)))
            output.append(UInt8(0x80 | ((value >> 12) & 0x3F)))
            output.append(UInt8(0x80 | ((value >> 6) & 0x3F)))
            output.append(UInt8(0x80 | (value & 0x3F)))
        }
    }

    private static let windows1252: [UInt32: UInt32] = [
        0x80: 0x20AC, 0x82: 0x201A, 0x83: 0x0192, 0x84: 0x201E, 0x85: 0x2026, 0x86: 0x2020, 0x87: 0x2021,
        0x88: 0x02C6, 0x89: 0x2030, 0x8A: 0x0160, 0x8B: 0x2039, 0x8C: 0x0152, 0x8E: 0x017D, 0x91: 0x2018,
        0x92: 0x2019, 0x93: 0x201C, 0x94: 0x201D, 0x95: 0x2022, 0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02DC,
        0x99: 0x2122, 0x9A: 0x0161, 0x9B: 0x203A, 0x9C: 0x0153, 0x9E: 0x017E, 0x9F: 0x0178,
    ]

    /// Latin-1 supplement names for U+00A0...U+00FF, in code point order.
    private static let latin1Names = [
        "nbsp", "iexcl", "cent", "pound", "curren", "yen", "brvbar", "sect", "uml", "copy", "ordf", "laquo",
        "not", "shy", "reg", "macr", "deg", "plusmn", "sup2", "sup3", "acute", "micro", "para", "middot",
        "cedil", "sup1", "ordm", "raquo", "frac14", "frac12", "frac34", "iquest", "Agrave", "Aacute", "Acirc",
        "Atilde", "Auml", "Aring", "AElig", "Ccedil", "Egrave", "Eacute", "Ecirc", "Euml", "Igrave", "Iacute",
        "Icirc", "Iuml", "ETH", "Ntilde", "Ograve", "Oacute", "Ocirc", "Otilde", "Ouml", "times", "Oslash",
        "Ugrave", "Uacute", "Ucirc", "Uuml", "Yacute", "THORN", "szlig", "agrave", "aacute", "acirc", "atilde",
        "auml", "aring", "aelig", "ccedil", "egrave", "eacute", "ecirc", "euml", "igrave", "iacute", "icirc",
        "iuml", "eth", "ntilde", "ograve", "oacute", "ocirc", "otilde", "ouml", "divide", "oslash", "ugrave",
        "uacute", "ucirc", "uuml", "yacute", "thorn", "yuml",
    ]

    private static let otherEntities: [String: UInt32] = [
        // Markup-significant and ASCII punctuation.
        "quot": 0x22, "QUOT": 0x22, "amp": 0x26, "AMP": 0x26, "apos": 0x27, "lt": 0x3C, "LT": 0x3C,
        "gt": 0x3E, "GT": 0x3E, "Tab": 0x09, "NewLine": 0x0A, "excl": 0x21, "num": 0x23, "dollar": 0x24,
        "percnt": 0x25, "lpar": 0x28, "rpar": 0x29, "ast": 0x2A, "plus": 0x2B, "comma": 0x2C,
        "period": 0x2E, "sol": 0x2F, "colon": 0x3A, "semi": 0x3B, "equals": 0x3D, "quest": 0x3F,
        "commat": 0x40, "lsqb": 0x5B, "lbrack": 0x5B, "bsol": 0x5C, "rsqb": 0x5D, "rbrack": 0x5D,
        "Hat": 0x5E, "lowbar": 0x5F, "grave": 0x60, "lcub": 0x7B, "lbrace": 0x7B, "verbar": 0x7C,
        "vert": 0x7C, "rcub": 0x7D, "rbrace": 0x7D, "COPY": 0xA9, "REG": 0xAE, "half": 0xBD,
        "centerdot": 0xB7,
        // Latin Extended and spacing modifiers.
        "OElig": 0x152, "oelig": 0x153, "Scaron": 0x160, "scaron": 0x161, "Yuml": 0x178, "fnof": 0x192,
        "circ": 0x2C6, "tilde": 0x2DC,
        // Greek.
        "Alpha": 0x391, "Beta": 0x392, "Gamma": 0x393, "Delta": 0x394, "Epsilon": 0x395, "Zeta": 0x396,
        "Eta": 0x397, "Theta": 0x398, "Iota": 0x399, "Kappa": 0x39A, "Lambda": 0x39B, "Mu": 0x39C,
        "Nu": 0x39D, "Xi": 0x39E, "Omicron": 0x39F, "Pi": 0x3A0, "Rho": 0x3A1, "Sigma": 0x3A3,
        "Tau": 0x3A4, "Upsilon": 0x3A5, "Phi": 0x3A6, "Chi": 0x3A7, "Psi": 0x3A8, "Omega": 0x3A9,
        "alpha": 0x3B1, "beta": 0x3B2, "gamma": 0x3B3, "delta": 0x3B4, "epsilon": 0x3B5, "zeta": 0x3B6,
        "eta": 0x3B7, "theta": 0x3B8, "iota": 0x3B9, "kappa": 0x3BA, "lambda": 0x3BB, "mu": 0x3BC,
        "nu": 0x3BD, "xi": 0x3BE, "omicron": 0x3BF, "pi": 0x3C0, "rho": 0x3C1, "sigmaf": 0x3C2,
        "sigma": 0x3C3, "tau": 0x3C4, "upsilon": 0x3C5, "phi": 0x3C6, "chi": 0x3C7, "psi": 0x3C8,
        "omega": 0x3C9, "thetasym": 0x3D1, "upsih": 0x3D2, "piv": 0x3D6,
        // General punctuation.
        "ensp": 0x2002, "emsp": 0x2003, "thinsp": 0x2009, "zwnj": 0x200C, "zwj": 0x200D, "lrm": 0x200E,
        "rlm": 0x200F, "hyphen": 0x2010, "dash": 0x2010, "ndash": 0x2013, "mdash": 0x2014,
        "lsquo": 0x2018, "rsquo": 0x2019, "sbquo": 0x201A, "ldquo": 0x201C, "rdquo": 0x201D,
        "bdquo": 0x201E, "dagger": 0x2020, "Dagger": 0x2021, "bull": 0x2022, "hellip": 0x2026,
        "permil": 0x2030, "prime": 0x2032, "Prime": 0x2033, "lsaquo": 0x2039, "rsaquo": 0x203A,
        "oline": 0x203E, "frasl": 0x2044, "euro": 0x20AC,
        // Letterlike symbols and arrows.
        "image": 0x2111, "weierp": 0x2118, "real": 0x211C, "trade": 0x2122, "TRADE": 0x2122,
        "alefsym": 0x2135, "larr": 0x2190, "uarr": 0x2191, "rarr": 0x2192, "darr": 0x2193, "harr": 0x2194,
        "crarr": 0x21B5, "lArr": 0x21D0, "uArr": 0x21D1, "rArr": 0x21D2, "dArr": 0x21D3, "hArr": 0x21D4,
        // Mathematical operators.
        "forall": 0x2200, "part": 0x2202, "exist": 0x2203, "empty": 0x2205, "nabla": 0x2207,
        "isin": 0x2208, "notin": 0x2209, "ni": 0x220B, "prod": 0x220F, "sum": 0x2211, "minus": 0x2212,
        "lowast": 0x2217, "radic": 0x221A, "prop": 0x221D, "infin": 0x221E, "ang": 0x2220, "and": 0x2227,
        "or": 0x2228, "cap": 0x2229, "cup": 0x222A, "int": 0x222B, "there4": 0x2234, "sim": 0x223C,
        "cong": 0x2245, "asymp": 0x2248, "ne": 0x2260, "equiv": 0x2261, "le": 0x2264, "ge": 0x2265,
        "sub": 0x2282, "sup": 0x2283, "nsub": 0x2284, "sube": 0x2286, "supe": 0x2287, "oplus": 0x2295,
        "otimes": 0x2297, "perp": 0x22A5, "sdot": 0x22C5,
        // Technical, geometric and miscellaneous symbols.
        "lceil": 0x2308, "rceil": 0x2309, "lfloor": 0x230A, "rfloor": 0x230B, "lang": 0x27E8,
        "rang": 0x27E9, "loz": 0x25CA, "starf": 0x2605, "star": 0x2606, "spades": 0x2660, "clubs": 0x2663,
        "hearts": 0x2665, "diams": 0x2666, "check": 0x2713, "cross": 0x2717,
    ]

    static let namedEntities: [String: UInt32] = {
        var table = otherEntities
        for (offset, name) in latin1Names.enumerated() {
            table[name] = 0xA0 + UInt32(offset)
        }
        return table
    }()
}
