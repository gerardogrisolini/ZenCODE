import Foundation

/// A small CSS selector engine for ``WebHTMLNode`` trees.
///
/// Supported: type (`div`, case-insensitive), universal `*`, `#id`, `.class`,
/// compounds (`a.external#top`), attribute conditions `[attr]`, `[attr=v]`,
/// `[attr^=v]`, `[attr$=v]`, `[attr*=v]`, `[attr~=v]`, `[attr|=v]` (quoted or
/// unquoted values), descendant (whitespace) and child (`>`) combinators, and
/// comma-separated groups. Anything else (pseudo-classes, sibling
/// combinators, namespaces, attribute flags) is rejected so callers get a
/// clear error instead of silently wrong matches.
struct WebCSSSelector: Sendable, Equatable {
    enum Combinator: Sendable, Equatable {
        case descendant
        case child
    }

    enum AttributeMatch: Sendable, Equatable {
        case exists
        case equals(String)
        case prefix(String)
        case suffix(String)
        case substring(String)
        case includesWord(String)
        case dashPrefix(String)
    }

    struct AttributeCondition: Sendable, Equatable {
        let name: String
        let match: AttributeMatch
    }

    struct Compound: Sendable, Equatable {
        var tag: String?
        var ids: [String] = []
        var classes: [String] = []
        var attributes: [AttributeCondition] = []
    }

    /// `compounds[i]` and `compounds[i + 1]` are joined by `combinators[i]`.
    struct Complex: Sendable, Equatable {
        var compounds: [Compound]
        var combinators: [Combinator]
    }

    let source: String
    let groups: [Complex]

    init?(_ text: String) {
        var parser = SelectorParser(text)
        guard let groups = parser.parseSelectorList() else { return nil }
        self.source = text
        self.groups = groups
    }

    /// Matching elements below `root` (the root itself is excluded, like
    /// `querySelectorAll`), in document order. Descendants of a match are not
    /// reported again, so nested matches never duplicate content.
    static func select(_ selector: String, in root: WebHTMLNode) throws -> [WebHTMLNode] {
        guard let parsed = WebCSSSelector(selector) else {
            throw WebContentError.invalidSelector(selector)
        }
        return parsed.select(in: root)
    }

    func select(in root: WebHTMLNode) -> [WebHTMLNode] {
        var results: [WebHTMLNode] = []
        var stack: [WebHTMLNode] = root.children.reversed()
        while let node = stack.popLast() {
            if matches(node) {
                results.append(node)
                continue
            }
            if !node.children.isEmpty {
                stack.append(contentsOf: node.children.reversed())
            }
        }
        return results
    }

    func matches(_ node: WebHTMLNode) -> Bool {
        guard node.isElement else { return false }
        return groups.contains { Self.matches(node, complex: $0, index: $0.compounds.count - 1) }
    }

    /// Right-to-left matching with backtracking over ancestors. Recursion
    /// depth is bounded by the number of compounds, not by the DOM depth.
    private static func matches(_ node: WebHTMLNode, complex: Complex, index: Int) -> Bool {
        guard complex.compounds[index].matches(node) else { return false }
        guard index > 0 else { return true }
        switch complex.combinators[index - 1] {
        case .child:
            guard let parent = node.parent, parent.isElement else { return false }
            return matches(parent, complex: complex, index: index - 1)
        case .descendant:
            var ancestor = node.parent
            while let current = ancestor, current.isElement {
                if matches(current, complex: complex, index: index - 1) {
                    return true
                }
                ancestor = current.parent
            }
            return false
        }
    }
}

extension WebCSSSelector.Compound {
    func matches(_ node: WebHTMLNode) -> Bool {
        guard case .element(let name) = node.kind else { return false }
        if let tag, tag != name {
            return false
        }
        for id in ids where node.attributes["id"] != id {
            return false
        }
        if !classes.isEmpty {
            let classList = node.classList
            for name in classes where !classList.contains(name) {
                return false
            }
        }
        for condition in attributes where !condition.matches(node.attributes[condition.name]) {
            return false
        }
        return true
    }
}

extension WebCSSSelector.AttributeCondition {
    func matches(_ value: String?) -> Bool {
        guard let value else { return false }
        switch match {
        case .exists:
            return true
        case .equals(let expected):
            return value == expected
        case .prefix(let expected):
            return !expected.isEmpty && value.hasPrefix(expected)
        case .suffix(let expected):
            return !expected.isEmpty && value.hasSuffix(expected)
        case .substring(let expected):
            return !expected.isEmpty && value.contains(expected)
        case .includesWord(let expected):
            guard !expected.isEmpty, !expected.contains(where: { $0.isASCII && $0.isWhitespace }) else { return false }
            return value.split(whereSeparator: { $0.isASCII && $0.isWhitespace }).contains { $0 == expected }
        case .dashPrefix(let expected):
            return value == expected || value.hasPrefix(expected + "-")
        }
    }
}

// MARK: - Parsing

private struct SelectorParser {
    private let scalars: [Unicode.Scalar]
    private var index = 0

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    private var peek: Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private func peek(offset: Int) -> Unicode.Scalar? {
        index + offset < scalars.count ? scalars[index + offset] : nil
    }

    @discardableResult
    private mutating func skipWhitespace() -> Bool {
        let start = index
        while let scalar = peek, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" || scalar == "\u{0C}" {
            index += 1
        }
        return index > start
    }

    mutating func parseSelectorList() -> [WebCSSSelector.Complex]? {
        var groups: [WebCSSSelector.Complex] = []
        while true {
            skipWhitespace()
            guard let complex = parseComplex() else { return nil }
            groups.append(complex)
            skipWhitespace()
            guard let scalar = peek else { break }
            guard scalar == "," else { return nil }
            index += 1
        }
        return groups
    }

    private mutating func parseComplex() -> WebCSSSelector.Complex? {
        guard let first = parseCompound() else { return nil }
        var complex = WebCSSSelector.Complex(compounds: [first], combinators: [])
        while true {
            let hadWhitespace = skipWhitespace()
            guard let scalar = peek, scalar != "," else { break }
            let combinator: WebCSSSelector.Combinator
            if scalar == ">" {
                index += 1
                skipWhitespace()
                combinator = .child
            } else if hadWhitespace {
                combinator = .descendant
            } else {
                return nil
            }
            guard let compound = parseCompound() else { return nil }
            complex.compounds.append(compound)
            complex.combinators.append(combinator)
        }
        return complex
    }

    private mutating func parseCompound() -> WebCSSSelector.Compound? {
        var compound = WebCSSSelector.Compound()
        var consumed = false
        if peek == "*" {
            index += 1
            consumed = true
        } else if let identifier = parseIdentifier() {
            compound.tag = identifier.lowercased()
            consumed = true
        }

        loop: while let scalar = peek {
            switch scalar {
            case "#":
                index += 1
                guard let identifier = parseIdentifier() else { return nil }
                compound.ids.append(identifier)
            case ".":
                index += 1
                guard let identifier = parseIdentifier() else { return nil }
                compound.classes.append(identifier)
            case "[":
                index += 1
                guard let condition = parseAttributeCondition() else { return nil }
                compound.attributes.append(condition)
            default:
                break loop
            }
            consumed = true
        }
        return consumed ? compound : nil
    }

    private mutating func parseAttributeCondition() -> WebCSSSelector.AttributeCondition? {
        skipWhitespace()
        guard let name = parseIdentifier()?.lowercased() else { return nil }
        skipWhitespace()
        guard let scalar = peek else { return nil }
        if scalar == "]" {
            index += 1
            return .init(name: name, match: .exists)
        }

        var operation: Unicode.Scalar?
        if scalar == "=" {
            index += 1
        } else if ["^", "$", "*", "~", "|"].contains(scalar), peek(offset: 1) == "=" {
            operation = scalar
            index += 2
        } else {
            return nil
        }
        skipWhitespace()
        guard let value = parseAttributeValue() else { return nil }
        skipWhitespace()
        guard peek == "]" else { return nil }
        index += 1

        let match: WebCSSSelector.AttributeMatch
        switch operation {
        case "^": match = .prefix(value)
        case "$": match = .suffix(value)
        case "*": match = .substring(value)
        case "~": match = .includesWord(value)
        case "|": match = .dashPrefix(value)
        default: match = .equals(value)
        }
        return .init(name: name, match: match)
    }

    private mutating func parseAttributeValue() -> String? {
        guard let scalar = peek else { return nil }
        guard scalar == "\"" || scalar == "'" else {
            return parseIdentifier()
        }
        index += 1
        var value = String.UnicodeScalarView()
        while let current = peek {
            index += 1
            if current == scalar {
                return String(value)
            }
            if current == "\\" {
                guard let escaped = peek else { return nil }
                index += 1
                value.append(escaped)
            } else {
                value.append(current)
            }
        }
        return nil
    }

    /// CSS identifier: ASCII letters, digits, `-`, `_`, any non-ASCII scalar,
    /// or a backslash escape of the next character (hex escapes are not
    /// interpreted).
    private mutating func parseIdentifier() -> String? {
        var value = String.UnicodeScalarView()
        while let scalar = peek {
            if scalar == "\\" {
                guard let escaped = peek(offset: 1) else { return nil }
                value.append(escaped)
                index += 2
                continue
            }
            guard Self.isIdentifierScalar(scalar) else { break }
            value.append(scalar)
            index += 1
        }
        return value.isEmpty ? nil : String(value)
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", "-", "_":
            return true
        default:
            return !scalar.isASCII
        }
    }
}
