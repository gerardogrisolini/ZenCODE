//
//  ZenChoiceMenuState.swift
//  ZenApp
//
//  The pure logic of the choice menus (single, multiple, multiple with a
//  focused row): highlight, toggling, filtering and the answer, following the
//  terminal UI's checkbox menu.
//

import Foundation
import ZenCODECore

/// The state of a choice menu presented for a ``ChatPendingRequest``.
///
/// - The initial highlight is the selected (single) or focused (focused
///   multiple) item, else the current item, else the first one.
/// - ↑/↓ move the highlight among the visible items, clamped at the ends like
///   the terminal menu.
/// - Multiple and focused menus toggle items; the selection survives
///   filtering.
/// - The search query filters by title and detail.
public struct ZenChoiceMenuState: Equatable, Sendable {
    /// The kind of menu.
    public enum Mode: Equatable, Sendable {
        /// ``ChatPendingRequest/Kind/chooseOne(title:items:selectedID:)``.
        case single
        /// ``ChatPendingRequest/Kind/chooseMany(title:items:selectedIDs:)``.
        case multiple
        /// ``ChatPendingRequest/Kind/chooseManyWithFocus(title:items:selectedIDs:focusedID:toggleLabel:confirmLabel:)``:
        /// what the checkboxes toggle and what confirming on the focused row
        /// does.
        case focused(toggleLabel: String, confirmLabel: String)
    }

    /// Consecutive visible items with the same group, under its heading.
    public struct Section: Equatable, Sendable, Identifiable {
        /// The position of the section in display order.
        public let id: Int
        /// The group heading; `nil` for ungrouped items.
        public let title: String?
        public let items: [ChatChoiceItem]
    }

    public let title: String
    public let items: [ChatChoiceItem]
    public let mode: Mode
    /// The ticked items (multiple and focused menus).
    public private(set) var selectedIDs: Set<String>
    /// The highlighted (focused) item; `nil` when no item is visible.
    public private(set) var highlightedID: String?
    /// The search text; changing it keeps the highlight on a visible item.
    public var query: String = "" {
        didSet { reconcileHighlight() }
    }

    /// - Parameters:
    ///   - preferredHighlightID: The selected or focused item to highlight
    ///     first, when it is among `items`.
    public init(
        title: String,
        items: [ChatChoiceItem],
        mode: Mode,
        selectedIDs: Set<String> = [],
        preferredHighlightID: String? = nil
    ) {
        self.title = title
        self.items = items
        self.mode = mode
        self.selectedIDs = selectedIDs
        self.highlightedID = Self.initialHighlight(items: items, preferredID: preferredHighlightID)
    }

    /// The menu of a menu request; `nil` for the other kinds.
    public init?(kind: ChatPendingRequest.Kind) {
        switch kind {
        case let .chooseOne(title, items, selectedID):
            self.init(
                title: title,
                items: items,
                mode: .single,
                selectedIDs: selectedID.map { [$0] } ?? [],
                preferredHighlightID: selectedID
            )
        case let .chooseMany(title, items, selectedIDs):
            self.init(title: title, items: items, mode: .multiple, selectedIDs: selectedIDs)
        case let .chooseManyWithFocus(title, items, selectedIDs, focusedID, toggleLabel, confirmLabel):
            self.init(
                title: title,
                items: items,
                mode: .focused(toggleLabel: toggleLabel, confirmLabel: confirmLabel),
                selectedIDs: selectedIDs,
                preferredHighlightID: focusedID
            )
        case .toolConsent, .readLine, .workspaceAccess, .pickAttachment:
            return nil
        @unknown default:
            // A kind newer than the app is not a menu.
            return nil
        }
    }

    // MARK: - Visible items

    /// The items matching the query, in display order.
    public var visibleItems: [ChatChoiceItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return items
        }
        return items.filter { item in
            item.title.localizedStandardContains(needle)
                || (item.detail?.localizedStandardContains(needle) ?? false)
        }
    }

    /// The visible items grouped by consecutive runs of the same group.
    public var sections: [Section] {
        var sections: [Section] = []
        var currentTitle: String?
        var currentItems: [ChatChoiceItem] = []
        for item in visibleItems {
            if !currentItems.isEmpty, item.group != currentTitle {
                sections.append(Section(id: sections.count, title: currentTitle, items: currentItems))
                currentItems = []
            }
            currentTitle = item.group
            currentItems.append(item)
        }
        if !currentItems.isEmpty {
            sections.append(Section(id: sections.count, title: currentTitle, items: currentItems))
        }
        return sections
    }

    /// Whether the menu shows checkboxes.
    public var showsCheckboxes: Bool {
        mode != .single
    }

    /// Whether `id` is ticked (multiple and focused menus).
    public func isSelected(_ id: String) -> Bool {
        selectedIDs.contains(id)
    }

    // MARK: - Editing

    /// Highlights `id` when it is visible.
    public mutating func highlight(_ id: String) {
        guard visibleItems.contains(where: { $0.id == id }) else { return }
        highlightedID = id
    }

    /// Moves the highlight by `delta` visible rows, clamped at the ends.
    public mutating func moveHighlight(by delta: Int) {
        let visible = visibleItems
        guard !visible.isEmpty else {
            highlightedID = nil
            return
        }
        guard let index = visible.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = visible[0].id
            return
        }
        let target = min(max(index + delta, 0), visible.count - 1)
        highlightedID = visible[target].id
    }

    /// Ticks or unticks `id` (multiple and focused menus; no effect on a
    /// single choice).
    public mutating func toggle(_ id: String) {
        guard showsCheckboxes else { return }
        selectedIDs.formSymmetricDifference([id])
    }

    /// Toggles the highlighted item.
    public mutating func toggleHighlighted() {
        guard let highlightedID else { return }
        toggle(highlightedID)
    }

    // MARK: - Answers

    /// The answer of Return or of the confirm button: the highlighted item
    /// (single), the ticked items (multiple), the ticked items with the
    /// highlighted one (focused). `nil` when a single or focused menu has no
    /// visible highlighted item.
    public var confirmAnswer: ChatPendingRequest.Answer? {
        switch mode {
        case .single:
            return visibleHighlightedID.map { .choice($0) }
        case .multiple:
            return .choices(selectedIDs)
        case .focused:
            return visibleHighlightedID.map {
                .focusedChoice(ChatFocusedChoice(selectedIDs: selectedIDs, focusedID: $0))
            }
        }
    }

    /// Whether the menu can be confirmed now.
    public var canConfirm: Bool {
        confirmAnswer != nil
    }

    /// The answer of a double click on `id`: choosing it (single), confirming
    /// on it (focused); `nil` for a multiple menu, where a click toggles.
    public func activationAnswer(for id: String) -> ChatPendingRequest.Answer? {
        switch mode {
        case .single:
            return .choice(id)
        case .multiple:
            return nil
        case .focused:
            return .focusedChoice(ChatFocusedChoice(selectedIDs: selectedIDs, focusedID: id))
        }
    }

    // MARK: - Helpers

    private var visibleHighlightedID: String? {
        guard let highlightedID,
              visibleItems.contains(where: { $0.id == highlightedID }) else {
            return nil
        }
        return highlightedID
    }

    private mutating func reconcileHighlight() {
        let visible = visibleItems
        guard !visible.contains(where: { $0.id == highlightedID }) else { return }
        highlightedID = visible.first?.id
    }

    static func initialHighlight(items: [ChatChoiceItem], preferredID: String?) -> String? {
        if let preferredID, items.contains(where: { $0.id == preferredID }) {
            return preferredID
        }
        if let current = items.first(where: \.isCurrent) {
            return current.id
        }
        return items.first?.id
    }
}
