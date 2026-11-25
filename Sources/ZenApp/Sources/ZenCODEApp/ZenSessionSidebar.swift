//
//  ZenSessionSidebar.swift
//  ZenApp
//
//  The sidebar of a window: open and saved sessions of the workspace, with
//  New and Save in the sidebar's part of the toolbar.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// The sessions of a window's workspace.
struct ZenSessionSidebar: View {
    let window: ZenWorkspaceWindow
    let session: ZenWindowSession

    @Environment(\.zenPalette) private var palette
    /// The text that filters the saved sessions by name or model.
    @State private var query = ""
    /// The saved session the delete confirmation asks about.
    @State private var pendingDeletion: String?

    var body: some View {
        let sessions = window.sessions
        let sessionsByTitle = Dictionary(grouping: sessions) { $0.sessionTitle ?? "New session" }
        List {
            Section("Open sessions") {
                ForEach(sessions) { openSession in
                    let title = openSession.sessionTitle ?? "New session"
                    ZenOpenSessionRow(
                        session: openSession,
                        title: title,
                        showsIdentifier: openSession.sessionTitle == nil || (sessionsByTitle[title]?.count ?? 0) > 1,
                        isCurrent: openSession === session,
                        focus: { window.select(openSession) },
                        // Through `/exit`, as the File menu does, so a session that
                        // is running a turn refuses it.
                        close: { openSession.run(ZenAppCommands.exit.command) }
                    )
                }
            }
            Section("Saved sessions") {
                let saved = Self.filteredSavedSessions(session.savedSessions, query: query)
                if saved.isEmpty {
                    Text(query.isEmpty ? "No saved sessions" : "No matching saved sessions")
                        .foregroundStyle(palette.textMuted)
                } else {
                    ForEach(saved, id: \.name) { summary in
                        savedRow(summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.textMuted)
                    .accessibilityHidden(true)
                TextField("Filter sessions...", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(palette.surface)
        }
        .toolbar {
            actions
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { name in
            Button("Delete", role: .destructive) {
                session.deleteSavedSession(named: name)
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The saved session is removed from this workspace. The current conversation is not affected.")
        }
    }

    // MARK: - Rows

    private func savedRow(_ summary: ChatSavedSessionSummary) -> some View {
        let isLoaded = summary.name == session.currentSavedSessionName
        return Button {
            window.showSavedSession(named: summary.name)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.name)
                        .foregroundStyle(palette.textPrimary)
                        .fontWeight(isLoaded ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isLoaded {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(palette.accent)
                            .accessibilityLabel("Loaded")
                    }
                }
                HStack(spacing: 0) {
                    Text(summary.savedAt, format: .relative(presentation: .named))
                    Text(" · ")
                    Text(Self.messageCountText(summary.messageCount))
                        .foregroundStyle(palette.toolValue)
                    if let modelID = summary.modelID, !modelID.isEmpty {
                        Text(" · ")
                        Text(ZenStatusFormatting.modelDisplayName(modelID))
                    }
                }
                .font(.caption)
                .foregroundStyle(palette.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!session.canManageSessions)
        .help(session.canManageSessions
            ? "Load \(summary.name)"
            : "Wait for the current line to finish before loading a session")
        .contextMenu {
            Button("Load") {
                window.showSavedSession(named: summary.name)
            }
            .disabled(!session.canManageSessions)
            Divider()
            Button("Delete…", role: .destructive) {
                pendingDeletion = summary.name
            }
            .disabled(!session.canManageSessions)
        }
    }

    // MARK: - Toolbar

    /// New Session and Save, as icons in the sidebar's part of the toolbar:
    /// they hide with the sidebar.
    @ToolbarContentBuilder
    private var actions: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await window.openNewSession() }
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }
            .help("Start a new session in this window")
            .disabled(window.isClosed)
            Button {
                session.saveSession()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save the current session (/sessions save)")
            .disabled(!session.canManageSessions)
        }
    }

    // MARK: - Deletion

    private var deletionTitle: String {
        pendingDeletion.map { "Delete the saved session “\($0)”?" } ?? "Delete the saved session?"
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    pendingDeletion = nil
                }
            }
        )
    }

    // MARK: - Formatting

    /// The saved sessions matching `query` by name or model, most recently
    /// saved first. A blank query does not filter.
    static func filteredSavedSessions(
        _ sessions: [ChatSavedSessionSummary],
        query: String
    ) -> [ChatSavedSessionSummary] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? sessions : sessions.filter { summary in
            summary.name.localizedStandardContains(query)
                || summary.modelID?.localizedStandardContains(query) == true
        }
        return sortedSavedSessions(filtered)
    }

    /// The saved sessions, most recently saved first.
    static func sortedSavedSessions(_ sessions: [ChatSavedSessionSummary]) -> [ChatSavedSessionSummary] {
        sessions.sorted { lhs, rhs in
            lhs.savedAt != rhs.savedAt ? lhs.savedAt > rhs.savedAt : lhs.name < rhs.name
        }
    }

    /// `"1 message"`, `"N messages"`.
    static func messageCountText(_ count: Int) -> String {
        count == 1 ? "1 message" : "\(count) messages"
    }
}

/// One session of a system window, identified independently of its title.
/// The current session shows a checkmark; every other one shows a button that
/// closes it with `/exit`, disabled while the session would refuse the line.
private struct ZenOpenSessionRow: View {
    let session: ZenWindowSession
    let title: String
    let showsIdentifier: Bool
    let isCurrent: Bool
    let focus: () -> Void
    let close: () -> Void

    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Button(action: focus) {
                HStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(isCurrent ? palette.accent : palette.textMuted)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .foregroundStyle(palette.textPrimary)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .lineLimit(1)
                        if showsIdentifier {
                            Text("Session \(String(session.id.uuidString.prefix(8)))")
                                .font(.caption)
                                .foregroundStyle(palette.textMuted)
                        }
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(palette.accent)
                    .accessibilityLabel("Current session")
            } else {
                closeButton
            }
            activity
        }
    }

    /// Closes the session with `/exit`. The session is not the one on show, so
    /// a refusal would land in a transcript nobody sees: the button is disabled
    /// while the session would refuse the line (a turn is running).
    private var closeButton: some View {
        let refuses = session.refusesNow(ZenAppCommands.exit.command)
        return Button(action: close) {
            Image(systemName: "xmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(palette.textMuted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close session")
        .disabled(refuses)
        .help(refuses
            ? "Wait for the current line to finish before closing this session"
            : "Close this session (/exit)")
    }

    @ViewBuilder
    private var activity: some View {
        if session.pendingRequest != nil {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Waiting for input")
                .help("Waiting for input")
        } else if session.isGenerating || session.isBusy {
            ProgressView()
                .controlSize(.small)
                .tint(palette.accent)
                .scaleEffect(0.7)
                .frame(width: 14, height: 14)
                .accessibilityLabel(session.isGenerating ? "Generating" : "Working")
        }
    }
}
