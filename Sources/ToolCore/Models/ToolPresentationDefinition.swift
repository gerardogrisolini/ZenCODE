//
//  ToolPresentationDefinition.swift
//  ZenCODE
//

import Foundation

/// Rendering density requested by a presentation consumer. The definition is
/// terminal-independent; consumers remain responsible for layout and styling.
public nonisolated enum ToolPresentationMode: String, Codable, Hashable, Sendable {
    case compact
    case expanded
}

/// High-level intent of a tool call. This is presentation metadata only and
/// must never be used as an authorization or mutation-safety signal.
public nonisolated enum ToolPresentationKind: String, Codable, Hashable, Sendable {
    case read
    case search
    case create
    case edit
    case delete
    case move
    case execute
    case inspect
    case communicate
    case manage
    case other
}

/// Selects the payload from which a semantic presentation value is resolved.
public nonisolated enum ToolPresentationValueSource: String, Codable, Hashable, Sendable {
    /// The complete argument object, optionally narrowed by `keyPaths`.
    case arguments
    case resultOutput
    case resultSummary
    case toolName
    case literal
}

/// Describes a data-level transformation. It does not imply terminal layout,
/// truncation, coloring, or sanitization.
public nonisolated enum ToolPresentationValueFormat: String, Codable, Hashable, Sendable {
    case automatic
    case text
    case path
    case command
    case url
    case json
    case stringList
    case firstLine
    case lineCount
    case itemCount
    case languageHint
}

/// A serializable value selector used by targets, metadata, sections, and
/// summaries. Argument key paths are tried in order and use dot-separated keys;
/// an empty key-path list selects the complete argument object.
public nonisolated struct ToolPresentationValueDefinition: Codable, Hashable, Sendable {
    public let source: ToolPresentationValueSource
    public let keyPaths: [String]
    public let literalValue: String?
    public let format: ToolPresentationValueFormat
    public let separator: String?
    public let fallback: String?

    public init(
        source: ToolPresentationValueSource,
        keyPaths: [String] = [],
        literalValue: String? = nil,
        format: ToolPresentationValueFormat = .automatic,
        separator: String? = nil,
        fallback: String? = nil
    ) {
        self.source = source
        self.keyPaths = keyPaths
        self.literalValue = literalValue
        self.format = format
        self.separator = separator
        self.fallback = fallback
    }

    public static func argument(
        _ keyPaths: [String],
        format: ToolPresentationValueFormat = .automatic,
        separator: String? = nil,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .arguments,
            keyPaths: keyPaths,
            format: format,
            separator: separator,
            fallback: fallback
        )
    }

    public static func arguments(
        format: ToolPresentationValueFormat = .json,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .arguments,
            format: format,
            fallback: fallback
        )
    }

    public static func resultOutput(
        format: ToolPresentationValueFormat = .text,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .resultOutput,
            format: format,
            fallback: fallback
        )
    }

    public static func resultSummary(
        format: ToolPresentationValueFormat = .text,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .resultSummary,
            format: format,
            fallback: fallback
        )
    }

    public static func toolName(
        format: ToolPresentationValueFormat = .text
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(source: .toolName, format: format)
    }

    public static func literal(
        _ value: String,
        format: ToolPresentationValueFormat = .text
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .literal,
            literalValue: value,
            format: format
        )
    }

    /// Semantic validation is intentionally lightweight. Malformed definitions
    /// degrade to `.automatic` at descriptor boundaries instead of preventing a
    /// tool from being discovered or executed.
    public var isSemanticallyValid: Bool {
        switch source {
        case .literal:
            return literalValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .arguments:
            return literalValue == nil
        case .resultOutput, .resultSummary, .toolName:
            return literalValue == nil && keyPaths.isEmpty
        }
    }
}

public nonisolated struct ToolPresentationMetadataDefinition: Codable, Hashable, Sendable {
    public let label: String
    public let value: ToolPresentationValueDefinition
    public let modes: [ToolPresentationMode]

    public init(
        label: String,
        value: ToolPresentationValueDefinition,
        modes: [ToolPresentationMode] = [.expanded]
    ) {
        self.label = label
        self.value = value
        self.modes = modes
    }

    public var isSemanticallyValid: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.isSemanticallyValid
            && !modes.isEmpty
    }
}

public nonisolated enum ToolPresentationSectionKind: String, Codable, Hashable, Sendable {
    case parameters
    case code
    case diff
    case list
}

/// A semantic content section. Only fields meaningful to `kind` are consumed;
/// invalid combinations are ignored by the resolver through fail-soft
/// validation.
public nonisolated struct ToolPresentationSectionDefinition: Codable, Hashable, Sendable {
    public let kind: ToolPresentationSectionKind
    public let label: String?
    public let value: ToolPresentationValueDefinition?
    public let oldValue: ToolPresentationValueDefinition?
    public let newValue: ToolPresentationValueDefinition?
    public let languageHint: ToolPresentationValueDefinition?
    public let modes: [ToolPresentationMode]

    public init(
        kind: ToolPresentationSectionKind,
        label: String? = nil,
        value: ToolPresentationValueDefinition? = nil,
        oldValue: ToolPresentationValueDefinition? = nil,
        newValue: ToolPresentationValueDefinition? = nil,
        languageHint: ToolPresentationValueDefinition? = nil,
        modes: [ToolPresentationMode] = [.expanded]
    ) {
        self.kind = kind
        self.label = label
        self.value = value
        self.oldValue = oldValue
        self.newValue = newValue
        self.languageHint = languageHint
        self.modes = modes
    }

    public static func parameters(
        label: String? = "parameters",
        value: ToolPresentationValueDefinition = .arguments(),
        modes: [ToolPresentationMode] = [.expanded]
    ) -> ToolPresentationSectionDefinition {
        ToolPresentationSectionDefinition(
            kind: .parameters,
            label: label,
            value: value,
            modes: modes
        )
    }

    public static func code(
        label: String? = nil,
        value: ToolPresentationValueDefinition,
        languageHint: ToolPresentationValueDefinition? = nil,
        modes: [ToolPresentationMode] = [.expanded]
    ) -> ToolPresentationSectionDefinition {
        ToolPresentationSectionDefinition(
            kind: .code,
            label: label,
            value: value,
            languageHint: languageHint,
            modes: modes
        )
    }

    public static func diff(
        label: String? = nil,
        old oldValue: ToolPresentationValueDefinition,
        new newValue: ToolPresentationValueDefinition,
        languageHint: ToolPresentationValueDefinition? = nil,
        modes: [ToolPresentationMode] = [.expanded]
    ) -> ToolPresentationSectionDefinition {
        ToolPresentationSectionDefinition(
            kind: .diff,
            label: label,
            oldValue: oldValue,
            newValue: newValue,
            languageHint: languageHint,
            modes: modes
        )
    }

    public static func list(
        label: String? = nil,
        value: ToolPresentationValueDefinition,
        modes: [ToolPresentationMode] = [.expanded]
    ) -> ToolPresentationSectionDefinition {
        ToolPresentationSectionDefinition(
            kind: .list,
            label: label,
            value: value,
            modes: modes
        )
    }

    public var isSemanticallyValid: Bool {
        guard !modes.isEmpty,
              languageHint?.isSemanticallyValid != false else {
            return false
        }
        switch kind {
        case .parameters, .code, .list:
            return value?.isSemanticallyValid == true
                && oldValue == nil
                && newValue == nil
        case .diff:
            return value == nil
                && oldValue?.isSemanticallyValid == true
                && newValue?.isSemanticallyValid == true
        }
    }
}

public nonisolated enum ToolPresentationSummaryStrategy: String, Codable, Hashable, Sendable {
    case value
    case firstLine
    case lineCount
    case numberedLineCount
    case itemCount
}

public nonisolated struct ToolPresentationSummaryDefinition: Codable, Hashable, Sendable {
    public let value: ToolPresentationValueDefinition
    public let strategy: ToolPresentationSummaryStrategy
    public let label: String?
    public let modes: [ToolPresentationMode]

    public init(
        value: ToolPresentationValueDefinition,
        strategy: ToolPresentationSummaryStrategy = .value,
        label: String? = nil,
        modes: [ToolPresentationMode] = [.compact, .expanded]
    ) {
        self.value = value
        self.strategy = strategy
        self.label = label
        self.modes = modes
    }

    public var isSemanticallyValid: Bool {
        value.isSemanticallyValid && !modes.isEmpty
    }
}

public extension ToolPresentationDefinition {
    /// Concise factory for the common title/action/target/parameters/summary
    /// shape. It keeps definitions adjacent to tool implementations without
    /// requiring each feature to repeat the structural boilerplate.
    static func standard(
        title: String,
        action: String,
        kind: ToolPresentationKind,
        targetKeyPaths: [String] = [],
        targetFormat: ToolPresentationValueFormat = .automatic,
        includesParameters: Bool = true,
        summaryStrategy: ToolPresentationSummaryStrategy? = .firstLine
    ) -> ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: title,
            action: action,
            kind: kind,
            target: targetKeyPaths.isEmpty
                ? nil
                : .argument(targetKeyPaths, format: targetFormat),
            sections: includesParameters ? [.parameters()] : [],
            summary: summaryStrategy.map {
                ToolPresentationSummaryDefinition(
                    value: .resultSummary(),
                    strategy: $0,
                    label: "summary"
                )
            }
        )
    }

    static func fileRead(
        title: String = "File",
        action: String = "Read",
        targetKeyPaths: [String] = ["file_path", "path"],
        includesParameters: Bool = true
    ) -> ToolPresentationDefinition {
        let target = ToolPresentationValueDefinition.argument(
            targetKeyPaths,
            format: .path
        )
        return ToolPresentationDefinition(
            title: title,
            action: action,
            kind: .read,
            target: target,
            sections: (includesParameters ? [.parameters()] : []) + [
                .code(
                    label: "content",
                    value: .resultOutput(),
                    languageHint: .argument(
                        targetKeyPaths,
                        format: .languageHint
                    )
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultOutput(),
                strategy: .numberedLineCount,
                label: "summary"
            )
        )
    }

    static func fileWrite(
        title: String = "File",
        action: String = "Write",
        targetKeyPaths: [String] = ["file_path", "path"],
        contentKeyPaths: [String] = ["content", "text"]
    ) -> ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: title,
            action: action,
            kind: .edit,
            target: .argument(targetKeyPaths, format: .path),
            sections: [
                .parameters(),
                .code(
                    label: "content",
                    value: .argument(contentKeyPaths, format: .text),
                    languageHint: .argument(
                        targetKeyPaths,
                        format: .languageHint
                    )
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )
    }

    static func fileEdit(
        title: String = "File",
        action: String = "Edit",
        targetKeyPaths: [String] = ["file_path", "path"],
        oldKeyPaths: [String] = ["oldString", "old_string"],
        newKeyPaths: [String] = ["newString", "new_string"]
    ) -> ToolPresentationDefinition {
        ToolPresentationDefinition(
            title: title,
            action: action,
            kind: .edit,
            target: .argument(targetKeyPaths, format: .path),
            sections: [
                .parameters(),
                .diff(
                    label: "change",
                    old: .argument(oldKeyPaths, format: .text),
                    new: .argument(newKeyPaths, format: .text),
                    languageHint: .argument(
                        targetKeyPaths,
                        format: .languageHint
                    )
                )
            ],
            summary: ToolPresentationSummaryDefinition(
                value: .resultSummary(),
                strategy: .firstLine,
                label: "summary"
            )
        )
    }
}

public nonisolated enum ToolPresentationDefinitionStrategy: String, Codable, Hashable, Sendable {
    case automatic
    case semantic
}

/// Declarative, serializable, TUI-independent presentation metadata for a tool.
/// It describes *what* may be shown; terminal consumers retain ownership of
/// status glyphs, duration/exit metadata, sanitization, layout, truncation,
/// colors, diff style, and redraw behavior.
public nonisolated struct ToolPresentationDefinition: Codable, Hashable, Sendable {
    public let strategy: ToolPresentationDefinitionStrategy
    public let title: String?
    public let action: String?
    public let kind: ToolPresentationKind?
    public let target: ToolPresentationValueDefinition?
    public let metadata: [ToolPresentationMetadataDefinition]
    public let sections: [ToolPresentationSectionDefinition]
    public let summary: ToolPresentationSummaryDefinition?

    public static let automatic = ToolPresentationDefinition(
        strategy: .automatic,
        title: nil,
        action: nil,
        kind: nil,
        target: nil,
        metadata: [],
        sections: [],
        summary: nil
    )

    public init(
        title: String? = nil,
        action: String? = nil,
        kind: ToolPresentationKind? = nil,
        target: ToolPresentationValueDefinition? = nil,
        metadata: [ToolPresentationMetadataDefinition] = [],
        sections: [ToolPresentationSectionDefinition] = [],
        summary: ToolPresentationSummaryDefinition? = nil
    ) {
        self.init(
            strategy: .semantic,
            title: title,
            action: action,
            kind: kind,
            target: target,
            metadata: metadata,
            sections: sections,
            summary: summary
        )
    }

    private init(
        strategy: ToolPresentationDefinitionStrategy,
        title: String?,
        action: String?,
        kind: ToolPresentationKind?,
        target: ToolPresentationValueDefinition?,
        metadata: [ToolPresentationMetadataDefinition],
        sections: [ToolPresentationSectionDefinition],
        summary: ToolPresentationSummaryDefinition?
    ) {
        self.strategy = strategy
        self.title = title
        self.action = action
        self.kind = kind
        self.target = target
        self.metadata = metadata
        self.sections = sections
        self.summary = summary
    }

    public var isAutomatic: Bool {
        strategy == .automatic
    }

    public var isSemanticallyValid: Bool {
        switch strategy {
        case .automatic:
            return title == nil
                && action == nil
                && kind == nil
                && target == nil
                && metadata.isEmpty
                && sections.isEmpty
                && summary == nil
        case .semantic:
            let hasIdentity = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                || kind != nil
            let hasContent = target != nil || !metadata.isEmpty || !sections.isEmpty || summary != nil
            return (hasIdentity || hasContent)
                && target?.isSemanticallyValid != false
                && metadata.allSatisfy(\.isSemanticallyValid)
                && sections.allSatisfy(\.isSemanticallyValid)
                && summary?.isSemanticallyValid != false
        }
    }

    /// Boundary normalization used by descriptor decoders. A syntactically valid
    /// but semantically malformed third-party definition must not make its tool
    /// unavailable.
    public var validOrAutomatic: ToolPresentationDefinition {
        isSemanticallyValid ? self : .automatic
    }
}
