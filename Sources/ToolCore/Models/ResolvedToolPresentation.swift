//
//  ResolvedToolPresentation.swift
//  ZenCODE
//

import Foundation

/// A resolved metadata entry. Values remain untrusted text; renderers must
/// sanitize and bound them before display.
public nonisolated struct ToolPresentationMetadata: Hashable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// Semantic content emitted by `ToolPresentationResolver`. These cases describe
/// data, not terminal rows or styled strings.
public nonisolated enum ToolPresentationElement: Hashable, Sendable {
    case parameters(label: String?, value: JSONValue)
    case code(label: String?, content: String, languageHint: String?)
    case diff(
        label: String?,
        old: String,
        new: String,
        languageHint: String?
    )
    case list(label: String?, items: [JSONValue])
    case summary(label: String?, text: String)
}

/// TUI-independent presentation resolved for one call/result pair and display
/// mode. Status icons, timing, exit codes, ANSI, sanitization, truncation,
/// wrapping, diff layout, and redraw remain consumer responsibilities.
public nonisolated struct ResolvedToolPresentation: Hashable, Sendable {
    public let mode: ToolPresentationMode
    public let title: String
    public let action: String?
    public let target: String?
    public let kind: ToolPresentationKind
    public let metadata: [ToolPresentationMetadata]
    public let elements: [ToolPresentationElement]

    public init(
        mode: ToolPresentationMode,
        title: String,
        action: String?,
        target: String?,
        kind: ToolPresentationKind,
        metadata: [ToolPresentationMetadata],
        elements: [ToolPresentationElement]
    ) {
        self.mode = mode
        self.title = title
        self.action = action
        self.target = target
        self.kind = kind
        self.metadata = metadata
        self.elements = elements
    }
}
