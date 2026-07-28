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
    /// A value assembled from other declarative value definitions.
    case composite
}

public nonisolated enum ToolPresentationValueSelection: String, Codable, Hashable, Sendable {
    /// Uses the first key path that resolves to a value.
    case first
    /// Collects and flattens values from every matching key path.
    case collect
    /// Selects the first matching `itemKeyPaths` value for each element in the
    /// first array resolved by `keyPaths`.
    case perItemFirst
}

public nonisolated enum ToolPresentationValueComposition: String, Codable, Hashable, Sendable {
    case firstAvailable
    case joined
    case collected
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
    /// Extracts normalized file paths from an apply-patch/unified-diff payload.
    case patchPaths
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
    public let selection: ToolPresentationValueSelection?
    public let itemKeyPaths: [String]?
    public let components: [ToolPresentationValueDefinition]?
    public let composition: ToolPresentationValueComposition?
    public let prefix: String?
    public let suffix: String?

    public init(
        source: ToolPresentationValueSource,
        keyPaths: [String] = [],
        literalValue: String? = nil,
        format: ToolPresentationValueFormat = .automatic,
        separator: String? = nil,
        fallback: String? = nil,
        selection: ToolPresentationValueSelection? = nil,
        itemKeyPaths: [String]? = nil,
        components: [ToolPresentationValueDefinition]? = nil,
        composition: ToolPresentationValueComposition? = nil,
        prefix: String? = nil,
        suffix: String? = nil
    ) {
        self.source = source
        self.keyPaths = keyPaths
        self.literalValue = literalValue
        self.format = format
        self.separator = separator
        self.fallback = fallback
        self.selection = selection
        self.itemKeyPaths = itemKeyPaths
        self.components = components
        self.composition = composition
        self.prefix = prefix
        self.suffix = suffix
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

    public static func collectedArguments(
        _ keyPaths: [String],
        format: ToolPresentationValueFormat = .stringList,
        separator: String? = nil,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .arguments,
            keyPaths: keyPaths,
            format: format,
            separator: separator,
            fallback: fallback,
            selection: .collect
        )
    }

    public static func itemArguments(
        _ collectionKeyPaths: [String],
        itemKeyPaths: [String],
        format: ToolPresentationValueFormat = .stringList,
        separator: String? = nil,
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .arguments,
            keyPaths: collectionKeyPaths,
            format: format,
            separator: separator,
            fallback: fallback,
            selection: .perItemFirst,
            itemKeyPaths: itemKeyPaths
        )
    }

    public static func firstAvailable(
        _ components: [ToolPresentationValueDefinition],
        fallback: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .composite,
            fallback: fallback,
            components: components,
            composition: .firstAvailable
        )
    }

    public static func joined(
        _ components: [ToolPresentationValueDefinition],
        separator: String
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .composite,
            separator: separator,
            components: components,
            composition: .joined
        )
    }

    public static func collected(
        _ components: [ToolPresentationValueDefinition],
        separator: String? = nil
    ) -> ToolPresentationValueDefinition {
        ToolPresentationValueDefinition(
            source: .composite,
            format: .stringList,
            separator: separator,
            components: components,
            composition: .collected
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

    /// Semantic validation is intentionally lightweight so tool owners can
    /// verify definitions without coupling the wire contract to a renderer.
    public var isSemanticallyValid: Bool {
        switch source {
        case .literal:
            return literalValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .arguments:
            return literalValue == nil
        case .resultOutput, .resultSummary, .toolName:
            return literalValue == nil && keyPaths.isEmpty
        case .composite:
            return literalValue == nil
                && keyPaths.isEmpty
                && composition != nil
                && components?.isEmpty == false
                && components?.allSatisfy(\.isSemanticallyValid) == true
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

/// Declarative, serializable, TUI-independent presentation metadata for a tool.
/// It describes *what* may be shown; terminal consumers retain ownership of
/// status glyphs, duration/exit metadata, sanitization, layout, truncation,
/// colors, diff style, and redraw behavior.
public nonisolated struct ToolPresentationDefinition: Codable, Hashable, Sendable {
    public let title: String?
    public let action: String?
    public let kind: ToolPresentationKind?
    public let target: ToolPresentationValueDefinition?
    public let metadata: [ToolPresentationMetadataDefinition]
    public let sections: [ToolPresentationSectionDefinition]
    public let summary: ToolPresentationSummaryDefinition?

    public init(
        title: String? = nil,
        action: String? = nil,
        kind: ToolPresentationKind? = nil,
        target: ToolPresentationValueDefinition? = nil,
        metadata: [ToolPresentationMetadataDefinition] = [],
        sections: [ToolPresentationSectionDefinition] = [],
        summary: ToolPresentationSummaryDefinition? = nil
    ) {
        self.title = title
        self.action = action
        self.kind = kind
        self.target = target
        self.metadata = metadata
        self.sections = sections
        self.summary = summary
    }

    public var isSemanticallyValid: Bool {
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
