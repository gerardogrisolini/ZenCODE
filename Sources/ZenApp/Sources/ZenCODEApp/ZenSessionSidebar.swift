//
//  ZenSessionSidebar.swift
//  ZenApp
//
//  The sidebar of a window, the native rendition of `/sessions`: the current
//  session and the saved sessions of the workspace, with New and Save.
//

import Foundation
import SwiftUI
import ZenAppControls
import ZenAppSession
import ZenAppTheme
import ZenCODECore

/// The sessions of a window's workspace.
struct ZenSessionSidebar: View {
    let session: ZenWindowSession

    @Environment(\.zenPalette) private var palette
    /// The saved session the delete confirmation asks about.
    @State private var pendingDeletion: String?

    var body: some View {
        List {
            Section("Current session") {
                currentRow
            }
            Section("Saved sessions") {
                let saved = Self.sortedSavedSessions(session.savedSessions)
                if saved.isEmpty {
                    Text("No saved sessions")
                        .foregroundStyle(palette.textMuted)
                } else {
                    ForEach(saved, id: \.name) { summary in
                        savedRow(summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
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

    private var currentRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(palette.accent)
            Text(session.sessionTitle ?? "New session")
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if session.isGenerating {
                ProgressView()
                    .controlSize(.small)
                    .tint(palette.accent)
                    .scaleEffect(0.7)
                    .frame(width: 14, height: 14)
                    .accessibilityLabel("Generating")
            }
        }
    }

    private func savedRow(_ summary: ChatSavedSessionSummary) -> some View {
        let isLoaded = summary.name == session.currentSavedSessionName
        return Button {
            session.loadSavedSession(named: summary.name)
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
                        .foregroundStyle(palette.accentCount)
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
        .help("Load \(summary.name)")
        .contextMenu {
            Button("Load") {
                session.loadSavedSession(named: summary.name)
            }
            Divider()
            Button("Delete…", role: .destructive) {
                pendingDeletion = summary.name
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                session.startNewSession()
            } label: {
                Label("New Session", systemImage: "square.and.pencil")
            }
            .help("Start a new session (/sessions new)")
            Button {
                session.saveSession()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save the current session (/sessions save)")
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
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
