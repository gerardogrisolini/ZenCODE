import Foundation

/// A deliberately small, mutable DOM produced by ``WebHTMLParser`` and consumed
/// by ``WebCSSSelector`` and ``WebMarkdownConverter``.
///
/// Trees are built and consumed on a single task, so the type is intentionally
/// not `Sendable`. Every traversal helper is iterative and teardown in `deinit`
/// is iterative too, so pathological nesting cannot exhaust the stack.
final class WebHTMLNode {
    enum Kind: Equatable {
        case document
        /// Element with a lowercased tag name.
        case element(String)
        /// Raw character data. Entity references are *not* decoded here; the
        /// converter decodes each run exactly once.
        case text(String)
        case comment
    }

    var kind: Kind
    /// Lowercased attribute names mapped to entity-decoded values.
    var attributes: [String: String]
    var children: [WebHTMLNode]
    weak var parent: WebHTMLNode?

    init(kind: Kind, attributes: [String: String] = [:], children: [WebHTMLNode] = []) {
        self.kind = kind
        self.attributes = attributes
        self.children = []
        for child in children {
            appendChild(child)
        }
    }

    deinit {
        // Releasing a deep tree recursively (deinit -> children array -> deinit
        // ...) can overflow small thread stacks. Detach uniquely owned subtrees
        // onto a heap worklist so every node is released with no children left.
        guard !children.isEmpty else { return }
        var pending = children
        children = []
        while var node = pending.popLast() {
            if isKnownUniquelyReferenced(&node), !node.children.isEmpty {
                pending.append(contentsOf: node.children)
                node.children = []
            }
        }
    }

    var tagName: String? {
        if case .element(let name) = kind {
            return name
        }
        return nil
    }

    var isElement: Bool {
        if case .element = kind {
            return true
        }
        return false
    }

    /// Raw text of a text node, `nil` for every other kind.
    var text: String? {
        if case .text(let value) = kind {
            return value
        }
        return nil
    }

    func attribute(_ name: String) -> String? {
        if let value = attributes[name] {
            return value
        }
        let lowered = name.lowercased()
        return lowered == name ? nil : attributes[lowered]
    }

    var id: String? {
        attributes["id"]
    }

    var classList: [String] {
        guard let value = attributes["class"] else { return [] }
        return value
            .split(whereSeparator: { $0.isASCII && $0.isWhitespace })
            .map(String.init)
    }

    /// Concatenated raw text of every descendant text node (no entity decoding,
    /// no whitespace normalization), like the DOM `textContent` property.
    var textContent: String {
        if case .text(let value) = kind {
            return value
        }
        var result = ""
        for node in descendants {
            if case .text(let value) = node.kind {
                result += value
            }
        }
        return result
    }

    /// Depth-first, pre-order (document order) traversal of every node below
    /// this one, excluding the node itself. Iterative, safe for deep trees.
    var descendants: Descendants {
        Descendants(root: self)
    }

    func appendChild(_ child: WebHTMLNode) {
        child.parent = self
        children.append(child)
    }

    struct Descendants: Sequence, IteratorProtocol {
        private var stack: [WebHTMLNode]

        init(root: WebHTMLNode) {
            stack = root.children.reversed()
        }

        mutating func next() -> WebHTMLNode? {
            guard let node = stack.popLast() else { return nil }
            if !node.children.isEmpty {
                stack.append(contentsOf: node.children.reversed())
            }
            return node
        }
    }
}
