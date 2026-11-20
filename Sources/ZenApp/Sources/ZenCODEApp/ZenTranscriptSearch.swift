//
//  ZenTranscriptSearch.swift
//  ZenApp
//
//  Search of the visible conversation rows and the live block, with stable
//  row IDs for scrolling and a small, testable selection state.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript
import ZenCODECore

struct ZenTranscriptSearchState: Equatable {
    var isPresented = false
    var query = ""
    private(set) var matchIDs: [String] = []
    private(set) var selectedIndex: Int?

    private var rows: [ZenConversationRow] = []
    private var liveItems: [ZenTranscriptItem] = []

    var selectedMatchID: String? {
        selectedIndex.flatMap { matchIDs.indices.contains($0) ? matchIDs[$0] : nil }
    }

    var statusText: String {
        guard !normalizedQuery.isEmpty else { return "" }
        guard !matchIDs.isEmpty else { return "No results" }
        return "\((selectedIndex ?? 0) + 1) of \(matchIDs.count)"
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func present() {
        isPresented = true
        refreshMatches()
    }

    mutating func dismiss() {
        isPresented = false
    }

    mutating func update(rows: [ZenConversationRow]) {
        self.rows = rows
        refreshMatches()
    }

    mutating func update(liveItems: [ZenTranscriptItem]) {
        self.liveItems = liveItems
        refreshMatches()
    }

    mutating func update(rows: [ZenConversationRow], liveItems: [ZenTranscriptItem]) {
        self.rows = rows
        self.liveItems = liveItems
        refreshMatches()
    }

    mutating func refreshMatches() {
        guard isPresented else { return }
        let query = normalizedQuery
        let selectedID = selectedMatchID
        guard !query.isEmpty else {
            matchIDs = []
            selectedIndex = nil
            return
        }
        var seen: Set<String> = []
        matchIDs = (rows.map(\.item) + liveItems).compactMap { item in
            guard !seen.contains(item.id),
                  Self.text(for: item.content).localizedStandardContains(query)
            else { return nil }
            seen.insert(item.id)
            return item.id
        }
        selectedIndex = selectedID.flatMap { matchIDs.firstIndex(of: $0) }
            ?? (matchIDs.isEmpty ? nil : 0)
    }

    mutating func move(by delta: Int) {
        guard !matchIDs.isEmpty else {
            selectedIndex = nil
            return
        }
        let current = selectedIndex ?? (delta >= 0 ? -1 : 0)
        selectedIndex = ((current + delta) % matchIDs.count + matchIDs.count) % matchIDs.count
    }

    /// The text the visible row contributes to search. Hidden tool calls and
    /// file artifacts never reach this function through `rows`.
    static func text(for content: ZenTranscriptItem.Content) -> String {
        switch content {
        case let .userPrompt(text, attachments, _):
            return ([text] + attachments.map(\.originalFilename)).joined(separator: "\n")
        case let .commandLine(text):
            return text
        case let .assistantText(text, _):
            return text
        case let .thought(text, _):
            return text
        case let .toolCall(call, result):
            let line = ZenToolCallFormatting.compactLine(for: call)
            return [
                line.title,
                line.target ?? "",
                result?.output ?? "",
                result?.summary ?? "",
            ].joined(separator: "\n")
        case .fileArtifacts:
            return ""
        case let .notice(notice):
            return ChatSessionNoticeText.text(for: notice)
        case let .workflowNotice(notice):
            return ChatSessionNoticeText.text(for: notice)
        case let .fileChangeSummary(summary):
            return summary.entries.map(\.path).joined(separator: "\n")
        case let .local(text, _):
            return text
        case let .taskGraph(overview):
            return overview.tasks.flatMap { [$0.task.title, $0.task.details ?? ""] }
                .joined(separator: "\n")
        }
    }
}

/// The menu-bar action of the key window's transcript search.
struct ZenTranscriptSearchAction {
    let present: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var zenTranscriptSearchAction: ZenTranscriptSearchAction?
}

struct ZenTranscriptSearchBar: View {
    @Binding var state: ZenTranscriptSearchState
    @FocusState private var isFieldFocused: Bool
    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(palette.textMuted)
                .accessibilityHidden(true)
            TextField("Find in transcript", text: $state.query)
                .textFieldStyle(.plain)
                .focused($isFieldFocused)
                .onSubmit { state.move(by: 1) }
                .onChange(of: state.query) { _, _ in state.refreshMatches() }
            Text(state.statusText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(palette.textMuted)
                .fixedSize()
            Button { state.move(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Previous result")
            .accessibilityLabel("Previous search result")
            .disabled(state.matchIDs.isEmpty)
            Button { state.move(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Next result")
            .accessibilityLabel("Next search result")
            .disabled(state.matchIDs.isEmpty)
            Button { state.dismiss() } label: {
                Image(systemName: "xmark")
            }
            .help("Close transcript search")
            .accessibilityLabel("Close transcript search")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(palette.surface)
        .onKeyPress(.escape) {
            state.dismiss()
            return .handled
        }
        .onAppear { isFieldFocused = true }
    }
}
