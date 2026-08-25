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

    enum SelectionState<Value: Hashable> {
        case multiple(Set<Value>)
        case single(Value?)

        var helpLines: [String] {
            switch self {
            case .multiple:
                ["↑/↓ move · Space/X toggle · A all · N none · Enter confirm · Esc/Q cancel"]
            case .single:
                ["↑/↓ move · Enter select · Esc/Q cancel"]
            }
        }
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
        guard case let .multiple(selectedValues)? = selectMenu(
            title: title, items: items, initialState: .multiple(initialSelection),
            focusedIndex: 0, reservedBottomRows: reservedBottomRows, shouldCancel: shouldCancel
        ) else { return nil }
        return selectedValues
    }

    public static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        reservedBottomRows: Int = 0
    ) -> Value? {
        selectOne(title: title, items: items, selected: initialSelection,
                  reservedBottomRows: reservedBottomRows, shouldCancel: nil)
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
        let focusedIndex = items.firstIndex { $0.value == initialSelection } ?? 0
        guard case let .single(selectedValue)? = selectMenu(
            title: title, items: items, initialState: .single(initialSelection),
            focusedIndex: focusedIndex, reservedBottomRows: reservedBottomRows, shouldCancel: shouldCancel
        ) else { return nil }
        return selectedValue
    }

    static func selectMenu<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        initialState: SelectionState<Value>,
        focusedIndex initialFocusedIndex: Int,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?
    ) -> SelectionState<Value>? {
        var state = initialState
        var focusedIndex = initialFocusedIndex
        var renderedFrame: RenderedFrame?
        AgentOutput.standardError.writeString("\u{1B}[?25l")
        defer { AgentOutput.standardError.writeString("\u{1B}[?25h") }

        let rawInput = TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                clear(frame: renderedFrame)
                renderedFrame = renderMenu(
                    title: title, items: items, selection: state, focusedIndex: focusedIndex,
                    reservedBottomRows: reservedBottomRows,
                    reserveSpaceBeforeDrawing: renderedFrame == nil
                )
                guard let key = readKey(rawInput: rawInput, shouldCancel: shouldCancel) else {
                    clear(frame: renderedFrame)
                    return nil
                }
                switch apply(key: key, items: items, state: &state, focusedIndex: &focusedIndex) {
                case .continue: continue
                case .submit:
                    clear(frame: renderedFrame)
                    return state
                case .cancel:
                    clear(frame: renderedFrame)
                    return nil
                }
            }
        }
    }

    enum SelectionAction { case `continue`, submit, cancel }

    static func apply<Value: Hashable>(
        key: Key,
        items: [TerminalCheckboxMenuItem<Value>],
        state: inout SelectionState<Value>,
        focusedIndex: inout Int
    ) -> SelectionAction {
        switch key {
        case .up:
            focusedIndex = max(0, focusedIndex - 1)
            if case .single = state { state = .single(items[focusedIndex].value) }
        case .down:
            focusedIndex = min(items.count - 1, focusedIndex + 1)
            if case .single = state { state = .single(items[focusedIndex].value) }
        case .toggle:
            switch state {
            case var .multiple(selectedValues):
                let value = items[focusedIndex].value
                selectedValues.formSymmetricDifference([value])
                state = .multiple(selectedValues)
            case .single:
                state = .single(items[focusedIndex].value)
                return .submit
            }
        case .selectAll:
            if case .multiple = state { state = .multiple(Set(items.map(\.value))) }
        case .selectNone:
            if case .multiple = state { state = .multiple([]) }
        case .submit:
            if case .single = state { state = .single(items[focusedIndex].value) }
            return .submit
        case .cancel:
            return .cancel
        case .unknown:
            break
        }
        return .continue
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
        let rawInput = TerminalRawInput()
        guard rawInput.beginRawMode() else {
            return fallbackPromptLine(
                title: title, prompt: prompt, defaultValue: defaultValue,
                allowEmpty: allowEmpty, help: help, reservedBottomRows: reservedBottomRows
            )
        }
        defer { rawInput.restoreRawMode() }
        return readPromptLine(
            title: title, prompt: prompt, defaultValue: defaultValue,
            allowEmpty: allowEmpty, help: help, reservedBottomRows: reservedBottomRows
        ) { readInputLine(rawInput: rawInput, shouldCancel: shouldCancel) }
    }

    static func fallbackPromptLine(
        title: String,
        prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String?,
        reservedBottomRows: Int
    ) -> String? {
        readPromptLine(
            title: title, prompt: prompt, defaultValue: defaultValue,
            allowEmpty: allowEmpty, help: help, reservedBottomRows: reservedBottomRows
        ) {
            Swift.readLine().map(InputLineReadResult.submitted) ?? .endOfInput
        }
    }

    static func readPromptLine(
        title: String,
        prompt: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String?,
        reservedBottomRows: Int,
        read: () -> InputLineReadResult
    ) -> String? {
        var didReserveFrameSpace = false
        while true {
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            let promptText = "\(prompt)\(suffix): "
            let helpLines = inputHelpLines(help)
            let renderedFrame = renderInput(
                title: title, prompt: promptText, help: help,
                reservedBottomRows: reservedBottomRows,
                reserveSpaceBeforeDrawing: !didReserveFrameSpace
            )
            didReserveFrameSpace = true
            let inputRow = renderedFrame.row + helpLines.count + 3
            let inputColumn = min(3 + promptText.count, terminalGeometry().columns)
            AgentOutput.standardError.writeString("\u{1B}[?25h\u{1B}[\(inputRow);\(inputColumn)H")

            switch read() {
            case let .submitted(rawValue):
                clear(frame: renderedFrame)
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "?", let help {
                    AgentOutput.standardError.writeString("\(help)\n")
                    continue
                }
                if value.isEmpty, let defaultValue { return defaultValue }
                if value.isEmpty, allowEmpty { return "" }
                if !value.isEmpty { return value }
            case .cancel, .endOfInput:
                clear(frame: renderedFrame)
                return nil
            }
        }
    }

}
