//
//  TerminalCheckboxMenu.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public struct TerminalCheckboxMenuItem<Value: Hashable> {
    public let value: Value
    public let title: String
    public let detail: String?
    public let groupTitle: String?

    public init(
        value: Value,
        title: String,
        detail: String?,
        groupTitle: String? = nil
    ) {
        self.value = value
        self.title = title
        self.detail = detail
        self.groupTitle = groupTitle
    }
}

/// Immutable value type, so it crosses isolation boundaries safely whenever its
/// payload does. This lets menus run off the actor that owns the chat state.
extension TerminalCheckboxMenuItem: Sendable where Value: Sendable {}

public enum TerminalCheckboxMenu {
    struct RenderedFrame {
        let row: Int
        let height: Int
    }

    struct RenderedMenuLine {
        let text: String
        let itemIndex: Int?
    }

    enum Key {
        case up
        case down
        case toggle
        case submit
        case cancel
        case selectAll
        case selectNone
        case unknown
    }

    enum InputLineReadResult {
        case submitted(String)
        case cancel
        case endOfInput
    }

    static let escapeSequenceInitialTimeout: Int32 = 120
    static let escapeSequenceContinuationTimeout: Int32 = 60
    static let escapeSequenceMaximumLength = 24
    /// Poll granularity used by cancellation-aware menu reads.
    static let cancellationPollTimeout: Int32 = 50

    /// Runs an interactive selection off the cooperative executor.
    ///
    /// The synchronous `select(...)` blocks its thread for the whole
    /// interaction. Called straight from a `@TerminalChatActor` method it would
    /// hold the actor — and therefore the entire chat runtime — until the
    /// operator answers. This variant keeps the same rendering and key handling
    /// but runs the blocking loop on a dedicated thread and unwinds on
    /// cancellation, returning `nil` exactly like an operator cancel.
    public static func selectOffActor<Value: Hashable & Sendable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        reservedBottomRows: Int = 0
    ) async -> Set<Value>? {
        await TerminalBlockingRead.run { token in
            select(
                title: title,
                items: items,
                selected: initialSelection,
                reservedBottomRows: reservedBottomRows,
                shouldCancel: token.isCancelled
            )
        }
    }

    /// Single-selection counterpart of ``selectOffActor(title:items:selected:reservedBottomRows:)``.
    public static func selectOneOffActor<Value: Hashable & Sendable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        reservedBottomRows: Int = 0
    ) async -> Value? {
        await TerminalBlockingRead.run { token in
            selectOne(
                title: title,
                items: items,
                selected: initialSelection,
                reservedBottomRows: reservedBottomRows,
                shouldCancel: token.isCancelled
            )
        }
    }

    /// Line-prompt counterpart of ``selectOffActor(title:items:selected:reservedBottomRows:)``.
    public static func promptLineOffActor(
        title: String,
        prompt: String,
        defaultValue: String? = nil,
        allowEmpty: Bool = true,
        help: String? = nil,
        reservedBottomRows: Int = 0
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            promptLine(
                title: title,
                prompt: prompt,
                defaultValue: defaultValue,
                allowEmpty: allowEmpty,
                help: help,
                reservedBottomRows: reservedBottomRows,
                shouldCancel: token.isCancelled
            )
        }
    }

    public static func select<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        reservedBottomRows: Int = 0
    ) -> Set<Value>? {
        select(
            title: title,
            items: items,
            selected: initialSelection,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: nil
        )
    }

    static func select<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> Set<Value>? {
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("\(title)\nNo selectable items.\n")
            return initialSelection
        }

        var selectedValues = initialSelection
        var focusedIndex = 0
        var renderedFrame: RenderedFrame?

        AgentOutput.standardError.writeString("\u{1B}[?25l")
        defer {
            AgentOutput.standardError.writeString("\u{1B}[?25h")
        }

        let rawInput = TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                clear(frame: renderedFrame)
                renderedFrame = render(
                    title: title,
                    items: items,
                    selectedValues: selectedValues,
                    focusedIndex: focusedIndex,
                    reservedBottomRows: reservedBottomRows,
                    reserveSpaceBeforeDrawing: renderedFrame == nil
                )

                guard let key = readKey(rawInput: rawInput, shouldCancel: shouldCancel) else {
                    clear(frame: renderedFrame)
                    return nil
                }

                switch key {
                case .up:
                    focusedIndex = max(0, focusedIndex - 1)
                case .down:
                    focusedIndex = min(items.count - 1, focusedIndex + 1)
                case .toggle:
                    let value = items[focusedIndex].value
                    if selectedValues.contains(value) {
                        selectedValues.remove(value)
                    } else {
                        selectedValues.insert(value)
                    }
                case .selectAll:
                    selectedValues = Set(items.map(\.value))
                case .selectNone:
                    selectedValues.removeAll()
                case .submit:
                    clear(frame: renderedFrame)
                    return selectedValues
                case .cancel:
                    clear(frame: renderedFrame)
                    return nil
                case .unknown:
                    continue
                }
            }
        }
    }

    public static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        reservedBottomRows: Int = 0
    ) -> Value? {
        selectOne(
            title: title,
            items: items,
            selected: initialSelection,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: nil
        )
    }

    static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> Value? {
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("\(title)\nNo selectable items.\n")
            return nil
        }

        var focusedIndex = items.firstIndex { item in
            item.value == initialSelection
        } ?? 0
        var selectedValue = initialSelection
        var renderedFrame: RenderedFrame?

        AgentOutput.standardError.writeString("\u{1B}[?25l")
        defer {
            AgentOutput.standardError.writeString("\u{1B}[?25h")
        }

        let rawInput = TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                clear(frame: renderedFrame)
                renderedFrame = renderSingle(
                    title: title,
                    items: items,
                    selectedValue: selectedValue,
                    focusedIndex: focusedIndex,
                    reservedBottomRows: reservedBottomRows,
                    reserveSpaceBeforeDrawing: renderedFrame == nil
                )

                guard let key = readKey(rawInput: rawInput, shouldCancel: shouldCancel) else {
                    clear(frame: renderedFrame)
                    return nil
                }

                switch key {
                case .up:
                    focusedIndex = max(0, focusedIndex - 1)
                    selectedValue = items[focusedIndex].value
                case .down:
                    focusedIndex = min(items.count - 1, focusedIndex + 1)
                    selectedValue = items[focusedIndex].value
                case .toggle, .submit:
                    clear(frame: renderedFrame)
                    return items[focusedIndex].value
                case .cancel:
                    clear(frame: renderedFrame)
                    return nil
                case .selectAll, .selectNone, .unknown:
                    continue
                }
            }
        }
    }

    public static func promptLine(
        title: String,
        prompt: String,
        defaultValue: String? = nil,
        allowEmpty: Bool = true,
        help: String? = nil,
        reservedBottomRows: Int = 0
    ) -> String? {
        promptLine(
            title: title,
            prompt: prompt,
            defaultValue: defaultValue,
            allowEmpty: allowEmpty,
            help: help,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: nil
        )
    }

    static func promptLine(
        title: String,
        prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String?,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> String? {
        var didReserveFrameSpace = false
        let rawInput = TerminalRawInput()
        guard rawInput.beginRawMode() else {
            return fallbackPromptLine(
                title: title,
                prompt: prompt,
                defaultValue: defaultValue,
                allowEmpty: allowEmpty,
                help: help,
                reservedBottomRows: reservedBottomRows
            )
        }
        defer {
            rawInput.restoreRawMode()
        }

        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            let promptText = "\(prompt)\(suffix): "
            let helpLines = inputHelpLines(help)
            let renderedFrame = renderInput(
                title: title,
                prompt: promptText,
                help: help,
                reservedBottomRows: reservedBottomRows,
                reserveSpaceBeforeDrawing: !didReserveFrameSpace
            )
            didReserveFrameSpace = true
            let inputRow = renderedFrame.row + helpLines.count + 3
            let inputColumn = min(3 + promptText.count, terminalGeometry().columns)
            AgentOutput.standardError.writeString("\u{1B}[?25h\u{1B}[\(inputRow);\(inputColumn)H")

            let readResult = readInputLine(rawInput: rawInput, shouldCancel: shouldCancel)
            switch readResult {
            case .submitted(let rawValue):
                clear(frame: renderedFrame)

                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "?", let help {
                    AgentOutput.standardError.writeString("\(help)\n")
                    continue
                }
                if value.isEmpty, let defaultValue {
                    return defaultValue
                }
                if value.isEmpty, allowEmpty {
                    return ""
                }
                if !value.isEmpty {
                    return value
                }
            case .cancel, .endOfInput:
                clear(frame: renderedFrame)
                return nil
            }
        }
    }

    static func fallbackPromptLine(
        title: String,
        prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String?,
        reservedBottomRows: Int
    ) -> String? {
        var didReserveFrameSpace = false
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            let promptText = "\(prompt)\(suffix): "
            let helpLines = inputHelpLines(help)
            let renderedFrame = renderInput(
                title: title,
                prompt: promptText,
                help: help,
                reservedBottomRows: reservedBottomRows,
                reserveSpaceBeforeDrawing: !didReserveFrameSpace
            )
            didReserveFrameSpace = true
            let inputRow = renderedFrame.row + helpLines.count + 3
            let inputColumn = min(3 + promptText.count, terminalGeometry().columns)
            AgentOutput.standardError.writeString("\u{1B}[?25h\u{1B}[\(inputRow);\(inputColumn)H")
            guard let rawValue = Swift.readLine() else {
                clear(frame: renderedFrame)
                return nil
            }
            clear(frame: renderedFrame)

            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "?", let help {
                AgentOutput.standardError.writeString("\(help)\n")
                continue
            }
            if value.isEmpty, let defaultValue {
                return defaultValue
            }
            if value.isEmpty, allowEmpty {
                return ""
            }
            if !value.isEmpty {
                return value
            }
        }
    }
}
