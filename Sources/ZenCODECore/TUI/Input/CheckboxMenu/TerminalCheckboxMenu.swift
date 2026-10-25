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
        /// Terminal height used to calculate `row`. Keeping it with the frame
        /// lets resize cleanup target the old geometry instead of clamping it
        /// against the already-shrunk terminal.
        let terminalRows: Int
        /// Terminal width used to render the frame. A zero value denotes a frame
        /// created by an older caller that did not retain width information.
        let terminalColumns: Int
        /// Status-bar rows that were reserved when this frame was painted. The
        /// value is used as a fallback when a resize happens before the status
        /// bar has published its new layout, so cleanup remains in the
        /// transcript viewport instead of erasing the bottom overlay.
        let reservedBottomRows: Int

        init(
            row: Int,
            height: Int,
            terminalRows: Int = 0,
            terminalColumns: Int = 0,
            reservedBottomRows: Int = 0
        ) {
            self.row = row
            self.height = height
            self.terminalRows = terminalRows
            self.terminalColumns = terminalColumns
            self.reservedBottomRows = max(0, reservedBottomRows)
        }
    }

    struct RenderedMenuLine: Equatable, Sendable {
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
        case resize
        case unknown
    }

    enum InputLineReadResult {
        case submitted(String)
        case resized(String)
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

    /// Multiple-selection counterpart of ``selectOffActor(title:items:selected:reservedBottomRows:)``
    /// that also reports the row under the cursor when the operator confirms.
    ///
    /// The cursor starts on `focused` (or the first row when it is `nil` or
    /// absent from `items`). `helpLines` replaces the default key-help line.
    /// Returns `nil` when the operator cancels or there is nothing to select.
    public static func selectWithFocusOffActor<Value: Hashable & Sendable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        focused initialFocus: Value?,
        helpLines: [String]? = nil,
        reservedBottomRows: Int = 0
    ) async -> (selected: Set<Value>, focused: Value)? {
        await TerminalBlockingRead.run { token in
            selectWithFocus(
                title: title,
                items: items,
                selected: initialSelection,
                focused: initialFocus,
                helpLines: helpLines,
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

    /// Synchronous multiple-selection menu that also returns the row under
    /// the cursor on confirmation. See ``selectWithFocusOffActor(title:items:selected:focused:helpLines:reservedBottomRows:)``.
    public static func selectWithFocus<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        focused initialFocus: Value?,
        helpLines: [String]? = nil,
        reservedBottomRows: Int = 0
    ) -> (selected: Set<Value>, focused: Value)? {
        selectWithFocus(
            title: title,
            items: items,
            selected: initialSelection,
            focused: initialFocus,
            helpLines: helpLines,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: nil
        )
    }

    static func selectWithFocus<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Set<Value>,
        focused initialFocus: Value?,
        helpLines: [String]?,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?,
        rawInput: TerminalRawInput? = nil,
        screen: TerminalPrimaryScreen? = nil
    ) -> (selected: Set<Value>, focused: Value)? {
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("\(title)\nNo selectable items.\n")
            return nil
        }
        let initialFocusedIndex = initialFocus.flatMap { focus in
            items.firstIndex { $0.value == focus }
        } ?? 0
        guard let result = selectMenuCore(
            title: title,
            items: items,
            initialState: .multiple(initialSelection),
            focusedIndex: initialFocusedIndex,
            helpLines: helpLines,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: shouldCancel,
            rawInput: rawInput,
            screen: screen
        ), case let .multiple(selectedValues) = result.state,
           items.indices.contains(result.focusedIndex) else { return nil }
        return (selectedValues, items[result.focusedIndex].value)
    }

    /// - Parameter header: Non-selectable context lines (for example a
    ///   summary table) rendered inside the menu frame above the items.
    public static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        header: [String] = [],
        reservedBottomRows: Int = 0
    ) -> Value? {
        selectOne(title: title, items: items, selected: initialSelection, header: header,
                  reservedBottomRows: reservedBottomRows, shouldCancel: nil)
    }

    static func selectOne<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected initialSelection: Value?,
        header: [String] = [],
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
            focusedIndex: focusedIndex, header: header,
            reservedBottomRows: reservedBottomRows, shouldCancel: shouldCancel
        ) else { return nil }
        return selectedValue
    }

    static func selectMenu<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        initialState: SelectionState<Value>,
        focusedIndex initialFocusedIndex: Int,
        header: [String] = [],
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?,
        rawInput injectedRawInput: TerminalRawInput? = nil,
        screen: TerminalPrimaryScreen? = nil
    ) -> SelectionState<Value>? {
        selectMenuCore(
            title: title,
            items: items,
            initialState: initialState,
            focusedIndex: initialFocusedIndex,
            header: header,
            reservedBottomRows: reservedBottomRows,
            shouldCancel: shouldCancel,
            rawInput: injectedRawInput,
            screen: screen
        )?.state
    }

    /// Shared menu loop. Besides the final selection state it reports the row
    /// under the cursor when the operator confirmed, and lets a caller replace
    /// the default key-help line of the selection mode.
    static func selectMenuCore<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        initialState: SelectionState<Value>,
        focusedIndex initialFocusedIndex: Int,
        header: [String] = [],
        helpLines helpLinesOverride: [String]? = nil,
        reservedBottomRows: Int,
        shouldCancel: (@Sendable () -> Bool)?,
        rawInput injectedRawInput: TerminalRawInput? = nil,
        screen: TerminalPrimaryScreen? = nil
    ) -> (state: SelectionState<Value>, focusedIndex: Int)? {
        var state = initialState
        var focusedIndex = initialFocusedIndex
        let modal = TerminalModalSession(screen: screen)
        defer { modal.close() }
        let layoutCancelled = modal.cancellationCheck
        let cancel: @Sendable () -> Bool = { layoutCancelled() || shouldCancel?() == true }
        let rawInput = injectedRawInput ?? TerminalRawInput()
        return rawInput.withRawTerminal {
            while true {
                if cancel() { return nil }
                let resizeGeneration = TerminalResizeCoordinator.shared.currentGeneration()
                let lines = groupedItemLines(items: items) { offset, item in
                    let focus = offset == focusedIndex ? ">" : " "
                    let marker: String
                    switch state {
                    case let .multiple(values): marker = values.contains(item.value) ? "[x]" : "[ ]"
                    case let .single(value): marker = value == item.value ? "(x)" : "( )"
                    }
                    return "\(focus) \(marker) \(item.title)\(detailSuffix(for: item))"
                }
                modal.update(.init(title: title, help: helpLinesOverride ?? state.helpLines,
                                   lines: lines, focusedIndex: focusedIndex, header: header))
                guard let key = readKey(
                    rawInput: rawInput,
                    shouldCancel: cancel,
                    resizeGeneration: resizeGeneration
                ), !cancel() else { return nil }
                switch apply(key: key, items: items, state: &state, focusedIndex: &focusedIndex) {
                case .continue: continue
                case .submit: return modal.accepted((state: state, focusedIndex: focusedIndex))
                case .cancel: return nil
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
        case .resize:
            break
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
        let modal = TerminalModalSession()
        let layoutCancelled = modal.cancellationCheck
        let cancel: @Sendable () -> Bool = { layoutCancelled() || shouldCancel?() == true }
        var inputBuffer = ""
        defer {
            rawInput.restoreRawMode()
            modal.close()
        }
        let suffix = defaultValue.map { " [\($0)]" } ?? ""
        func repaint(_ value: String) {
            modal.update(.init(title: title, help: inputHelpLines(help),
                lines: [.init(text: "\(prompt)\(suffix): ", itemIndex: 0)],
                focusedIndex: 0, input: value))
        }
        while true {
            if cancel() { return nil }
            let generation = TerminalResizeCoordinator.shared.currentGeneration()
            repaint(inputBuffer)
            switch readInputLine(rawInput: rawInput, shouldCancel: cancel,
                                 initialValue: inputBuffer, resizeGeneration: generation,
                                 onChange: repaint) {
            case let .resized(value): inputBuffer = value
            case let .submitted(rawValue):
                guard !modal.isCancelled else { return nil }
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                inputBuffer = ""
                if value == "?", help != nil { continue }
                if value.isEmpty, let defaultValue { return modal.accepted(defaultValue) }
                if value.isEmpty, allowEmpty { return modal.accepted("") }
                if !value.isEmpty { return modal.accepted(value) }
            case .cancel, .endOfInput: return nil
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
        screen: TerminalPrimaryScreen? = nil,
        read: () -> InputLineReadResult
    ) -> String? {
        let modal = TerminalModalSession(screen: screen)
        defer { modal.close() }
        var inputBuffer = ""
        while true {
            guard !modal.isCancelled else { return nil }
            let suffix = defaultValue.map { " [\($0)]" } ?? ""
            modal.update(.init(title: title, help: inputHelpLines(help),
                lines: [.init(text: "\(prompt)\(suffix): ", itemIndex: 0)],
                focusedIndex: 0, input: inputBuffer))
            switch read() {
            case let .submitted(rawValue):
                guard !modal.isCancelled else { return nil }
                inputBuffer = ""
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if value == "?", help != nil { continue }
                if value.isEmpty, let defaultValue { return modal.accepted(defaultValue) }
                if value.isEmpty, allowEmpty { return modal.accepted("") }
                if !value.isEmpty { return modal.accepted(value) }
            case let .resized(value): inputBuffer = value
            case .cancel, .endOfInput: return nil
            }
        }
    }

}
