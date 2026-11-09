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

enum Byte {
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

struct HTMLParseState {
    let bytes: UnsafeBufferPointer<UInt8>
    let document: WebHTMLNode
    var openNodes: [WebHTMLNode]
    var openNames: [String]
    var openDepths: [Int]
    /// Stack positions of every open element, indexed by tag name.
    var positions: [String: [Int]] = [:]
    /// Stack positions of open `listItemStopElements`.
    var stopPositions: [Int] = []
    var textStart: Int?

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
}
