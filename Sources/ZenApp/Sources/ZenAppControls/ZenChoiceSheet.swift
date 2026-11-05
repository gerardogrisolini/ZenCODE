//
//  ZenChoiceSheet.swift
//  ZenApp
//
//  The sheet of the single, multiple and focused choice menus.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// A choice menu sheet driven by a ``ZenChoiceMenuState``.
///
/// Items are grouped under muted section headers, details are secondary and
/// the current item is marked in the accent color. A search field filters by
/// title and detail; typing in the list starts a search.
/// - Single choice: ↑/↓ move the highlight, Return (or a double click)
///   chooses it.
/// - Multiple choice: checkboxes, Space (or a click) toggles, Return confirms.
/// - Focused multiple choice: checkboxes plus the focused row; Space (or a
///   click on the checkbox) toggles, Return (or a double click) confirms on
///   the focused row with the request's confirm label.
///
/// Esc or Cancel answers `nil`. The sheet answers once.
public struct ZenChoiceSheet: View {
    @Environment(\.zenPalette) private var palette
    @State private var state: ZenChoiceMenuState
    @State private var hasAnswered = false
    @FocusState private var focus: Field?
    private let onAnswer: @MainActor (ChatPendingRequest.Answer?) -> Void

    private enum Field: Hashable {
        case search
        case list
    }

    public init(
        state: ZenChoiceMenuState,
        onAnswer: @escaping @MainActor (ChatPendingRequest.Answer?) -> Void
    ) {
        self._state = State(initialValue: state)
        self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(palette.textPrimary)
            searchField
            list
            footer
        }
        .padding(20)
        .frame(minWidth: 460, idealWidth: 540, minHeight: 340, idealHeight: 480)
        .onAppear { focus = .list }
    }

    // MARK: - Parts

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.textMuted)
            TextField("Search", text: $state.query)
                .textFieldStyle(.plain)
                .foregroundStyle(palette.textPrimary)
                .focused($focus, equals: .search)
                .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
                    state.moveHighlight(by: -1)
                    return .handled
                }
                .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
                    state.moveHighlight(by: 1)
                    return .handled
                }
                .onKeyPress(.return, phases: .down) { _ in
                    confirm()
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    answer(nil)
                    return .handled
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: []) {
                    if state.visibleItems.isEmpty {
                        Text(state.items.isEmpty ? "No selectable items." : "No matches.")
                            .foregroundStyle(palette.textMuted)
                            .padding(8)
                    }
                    ForEach(state.sections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(palette.textMuted)
                                .padding(.horizontal, 8)
                                .padding(.top, section.id == 0 ? 0 : 8)
                        }
                        ForEach(section.items, id: \.id) { item in
                            row(item)
                                .id(item.id)
                        }
                    }
                }
                .padding(4)
            }
            .onChange(of: state.highlightedID) { _, newValue in
                if let newValue {
                    proxy.scrollTo(newValue)
                }
            }
            .onAppear {
                if let highlighted = state.highlightedID {
                    proxy.scrollTo(highlighted, anchor: .center)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .focusable()
        .focused($focus, equals: .list)
        .focusEffectDisabled()
        .onKeyPress(.upArrow, phases: [.down, .repeat]) { _ in
            state.moveHighlight(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow, phases: [.down, .repeat]) { _ in
            state.moveHighlight(by: 1)
            return .handled
        }
        .onKeyPress(.space, phases: .down) { _ in
            if state.showsCheckboxes {
                state.toggleHighlighted()
            } else {
                // Like the terminal menu, Space chooses in a single menu.
                confirm()
            }
            return .handled
        }
        .onKeyPress(.return, phases: .down) { _ in
            confirm()
            return .handled
        }
        .onKeyPress(.escape, phases: .down) { _ in
            answer(nil)
            return .handled
        }
        .onKeyPress(characters: .alphanumerics.union(.punctuationCharacters), phases: .down) { press in
            guard press.modifiers.isDisjoint(with: [.command, .control]) else {
                return .ignored
            }
            // Type to search.
            state.query.append(press.characters)
            focus = .search
            return .handled
        }
    }

    private func row(_ item: ChatChoiceItem) -> some View {
        let isHighlighted = item.id == state.highlightedID
        return HStack(spacing: 10) {
            if state.showsCheckboxes {
                Image(systemName: state.isSelected(item.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(state.isSelected(item.id) ? palette.accent : palette.textMuted)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        state.highlight(item.id)
                        state.toggle(item.id)
                    }
                    .accessibilityLabel(state.isSelected(item.id) ? "Selected" : "Not selected")
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .foregroundStyle(palette.textPrimary)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(palette.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if item.isCurrent {
                Text("current")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.accent.opacity(isHighlighted ? 0.18 : 0))
        }
        .contentShape(Rectangle())
        .gesture(rowGesture(for: item))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private func rowGesture(for item: ChatChoiceItem) -> AnyGesture<Void> {
        let click = TapGesture(count: 1).onEnded {
            state.highlight(item.id)
            if state.mode == .multiple {
                state.toggle(item.id)
            }
            focus = .list
        }
        guard state.mode != .multiple else {
            return AnyGesture(click)
        }
        let doubleClick = TapGesture(count: 2).onEnded {
            state.highlight(item.id)
            if let answer = state.activationAnswer(for: item.id) {
                self.answer(answer)
            }
        }
        return AnyGesture(doubleClick.exclusively(before: click).map { _ in () })
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text(hint)
                .font(.caption)
                .foregroundStyle(palette.textMuted)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Cancel", role: .cancel) {
                answer(nil)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            Button(confirmTitle) {
                confirm()
            }
            .buttonStyle(.glassProminent)
            .tint(palette.accent)
            .keyboardShortcut(.defaultAction)
            .disabled(!state.canConfirm)
        }
    }

    private var hint: String {
        switch state.mode {
        case .single:
            return "↑/↓ move · Return or double-click selects · Esc cancels"
        case .multiple:
            return "↑/↓ move · Space toggles · Return confirms · Esc cancels"
        case let .focused(toggleLabel, confirmLabel):
            return "↑/↓ move · Space toggles \(toggleLabel) · Return \(confirmLabel) · Esc cancels"
        }
    }

    private var confirmTitle: String {
        switch state.mode {
        case .single:
            return "Select"
        case .multiple:
            return "Confirm"
        case let .focused(_, confirmLabel):
            return Self.capitalizedFirst(confirmLabel)
        }
    }

    // MARK: - Answers

    private func confirm() {
        guard let answer = state.confirmAnswer else { return }
        self.answer(answer)
    }

    private func answer(_ answer: ChatPendingRequest.Answer?) {
        guard !hasAnswered else { return }
        hasAnswered = true
        onAnswer(answer)
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }
}

#Preview("Choice – single") {
    ZenChoiceSheet(
        state: ZenChoiceMenuState(
            title: "Choose the model",
            items: ZenControlsPreviewData.items,
            mode: .single,
            preferredHighlightID: "c"
        ),
        onAnswer: { _ in }
    )
}

#Preview("Choice – multiple") {
    ZenChoiceSheet(
        state: ZenChoiceMenuState(
            title: "Select the tool groups",
            items: ZenControlsPreviewData.items,
            mode: .multiple,
            selectedIDs: ["a", "c"]
        ),
        onAnswer: { _ in }
    )
}

#Preview("Choice – focused") {
    ZenChoiceSheet(
        state: ZenChoiceMenuState(
            title: "Project agents",
            items: ZenControlsPreviewData.items,
            mode: .focused(toggleLabel: "agents", confirmLabel: "use agent"),
            selectedIDs: ["b"],
            preferredHighlightID: "b"
        ),
        onAnswer: { _ in }
    )
}
