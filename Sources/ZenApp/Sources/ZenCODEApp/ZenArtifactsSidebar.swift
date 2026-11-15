//
//  ZenArtifactsSidebar.swift
//  ZenApp
//
//  The artifacts sidebar of a window, on the right like Xcode's inspectors:
//  the file artifacts of the session grouped by turn with a sticky header
//  per turn, one collapsed card per file, and the toolbar button that shows
//  and hides it.
//

import Foundation
import SwiftUI
import ZenAppSession
import ZenAppTheme
import ZenAppTranscript

/// The file artifacts of a window's session (``ZenWindowSession/fileArtifacts``),
/// oldest turn first: one `List` section per turn, whose header
/// (`Turn N · K files`) sticks at the top of the list while its section
/// scrolls, and one ``ZenFileArtifactCard`` per artifact. It reads the
/// artifacts in its own body, so they update live without running the
/// conversation's body.
struct ZenArtifactsSidebar: View {
    let session: ZenWindowSession

    @Environment(\.zenPalette) private var palette

    /// The insets of every row of the list, headers included: the 12 pt
    /// leading and trailing margins the `ScrollView` gave the cards, and a
    /// 12 pt gap between the cards of a section and between a section and
    /// the next one.
    private static let rowInsets = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)

    var body: some View {
        let groups = session.fileArtifacts
        if groups.isEmpty {
            Text("No file artifacts in this session.")
                .font(.callout)
                .foregroundStyle(palette.systemMessage)
                .multilineTextAlignment(.center)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(groups) { group in
                    Section(header: ZenArtifactTurnHeader(number: group.number, fileCount: group.entries.count)
                        .listRowInsets(Self.rowInsets)) {
                        ForEach(group.entries) { entry in
                            ZenFileArtifactCard(artifact: entry.artifact, agentID: entry.agentID)
                                .listRowInsets(Self.rowInsets)
                                .listRowSeparator(.hidden)
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }
}

/// The header of a turn in the artifacts sidebar: `Turn N · K files`.
struct ZenArtifactTurnHeader: View {
    let number: UInt64
    let fileCount: Int

    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Turn \(number)")
                .fontWeight(.bold)
                .foregroundStyle(palette.fileSummaryHeader)
            Text("· \(Self.fileCountText(fileCount))")
                .foregroundStyle(palette.textMuted)
        }
        .font(ZenFonts.monoSmall)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// `1 file` or `N files`.
    static func fileCountText(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}

/// The toolbar button that shows and hides the artifacts sidebar. It reads
/// whether the sidebar shows in its own body, so a toggle does not rebuild
/// the toolbar.
struct ZenArtifactsToolbarButton: View {
    let session: ZenWindowSession

    var body: some View {
        Button {
            session.toggleArtifactsSidebar()
        } label: {
            Label("Artifacts", systemImage: "sidebar.right")
        }
        .help(session.isArtifactsSidebarPresented
            ? "Hide the artifacts sidebar (/artifacts)"
            : "Show the artifacts sidebar (/artifacts)")
    }
}
