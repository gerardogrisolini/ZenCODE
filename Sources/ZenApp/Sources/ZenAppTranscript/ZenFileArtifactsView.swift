//
//  ZenFileArtifactsView.swift
//  ZenApp
//
//  The files a turn created, modified, or deleted, like the terminal's live
//  artifacts, and the presentation the sidebar's artifact cards share with
//  them (status icon, disclosure, explanation and diff).
//

import Foundation
import SwiftUI
import ToolCore
import ZenAppTheme
import ZenCODECore

/// The file artifacts of one turn: one compact row per file with its status
/// icon, path, and line counts, the explanation and the diff behind a
/// disclosure, and the agent that produced them when it was a sub-agent.
public struct ZenFileArtifactsView: View {
    private let turn: SessionFileArtifactHistory.Turn
    private let agentID: String?
    private let title: String?

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - turn: The artifact-history turn.
    ///   - agentID: The sub-agent that produced the artifacts, or `nil` for
    ///     the coordinator.
    public init(turn: SessionFileArtifactHistory.Turn, agentID: String?) {
        self.init(turn: turn, agentID: agentID, title: nil)
    }

    /// `title` replaces the file-count header (the `/artifacts` history
    /// names each turn).
    init(turn: SessionFileArtifactHistory.Turn, agentID: String?, title: String?) {
        self.turn = turn
        self.agentID = agentID
        self.title = title
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            ForEach(Array(turn.artifacts.enumerated()), id: \.offset) { _, artifact in
                ZenFileArtifactRow(artifact: artifact)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        let count = turn.artifacts.count
        var runs: [ZenTextRun] = [ZenTextRun(text: "🪬 ", color: palette.fileSummaryHeader)]
        if let title {
            runs.append(ZenTextRun(text: title + " — ", color: palette.fileSummaryHeader, isBold: true))
        }
        runs.append(ZenTextRun(text: "\(count)", color: palette.fileCount, isBold: true))
        runs.append(ZenTextRun(text: count == 1 ? " file" : " files", color: palette.filePath))
        if let agent = agentID.flatMap({ ZenTranscriptText.inline($0, limit: 120) }) {
            runs.append(ZenTextRun(text: "  ·  agent: ", color: palette.textMuted))
            runs.append(ZenTextRun(text: agent, color: palette.inlineCodeForeground))
        }
        return Text(AttributedString.zen(runs))
            .font(ZenFonts.monoSmall)
    }
}

/// One file artifact: the status icon, the path, the counts, and the
/// explanation and diff behind a disclosure.
struct ZenFileArtifactRow: View {
    let artifact: FileChangeArtifact

    @State private var isExpanded = false
    @Environment(\.zenPalette) private var palette

    var body: some View {
        let explanation = ZenFileArtifactPresentation.explanation(of: artifact)
        let canExpand = ZenFileArtifactPresentation.canExpand(artifact, explanation: explanation)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    ZenFileArtifactDisclosure(canExpand: canExpand, isExpanded: isExpanded)
                    ZenFileArtifactStatusIcon(status: artifact.status)
                    Text(AttributedString.zen(runs))
                        .font(ZenFonts.monoSmall)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canExpand)
            .help(artifact.absolutePath)

            if isExpanded {
                ZenFileArtifactDetails(artifact: artifact, explanation: explanation)
                    .padding(.leading, 18)
            }
        }
    }

    private var runs: [ZenTextRun] {
        var runs = [
            ZenTextRun(text: artifact.status.rawValue + " ", color: palette.fileMetadata),
            ZenTextRun(
                text: ZenTranscriptText.inline(ZenFileChangeFormatting.displayPath(of: artifact), limit: 1_000) ?? "",
                color: palette.filePath
            )
        ]
        if artifact.hasLineCounts {
            runs.append(ZenTextRun(text: "  +\(artifact.additions)", color: palette.fileAddition))
            runs.append(ZenTextRun(text: " −\(artifact.deletions)", color: palette.fileDeletion))
        }
        if artifact.isBinary {
            runs.append(ZenTextRun(text: " (binary)", color: palette.fileMetadata))
        }
        return runs
    }
}

// MARK: - Shared presentation

/// The presentation a file artifact's transcript row and sidebar card share:
/// the status icon and its color, and what a disclosure can reveal.
enum ZenFileArtifactPresentation {
    /// The SF Symbol of an artifact status.
    static func icon(for status: FileChangeArtifact.Status) -> String {
        switch status {
        case .added: "plus.square"
        case .modified: "pencil.line"
        case .deleted: "minus.square"
        case .unknown: "questionmark.square.dashed"
        @unknown default: "questionmark.square.dashed"
        }
    }

    /// The palette color of an artifact status icon.
    static func iconColor(for status: FileChangeArtifact.Status, in palette: ZenPalette) -> Color {
        switch status {
        case .added: palette.fileAddition
        case .modified: palette.fileCount
        case .deleted: palette.fileDeletion
        case .unknown: palette.fileMetadata
        @unknown default: palette.fileMetadata
        }
    }

    /// The explanation of an artifact, when it is not blank.
    static func explanation(of artifact: FileChangeArtifact) -> String? {
        ZenTranscriptText.nonBlank(artifact.explanation)
    }

    /// Whether the artifact carries the evidence of a diff, checked without
    /// computing it.
    static func hasDiffEvidence(_ artifact: FileChangeArtifact) -> Bool {
        guard !artifact.isBinary else { return false }
        return artifact.oldText != nil || artifact.newText != nil
            || ZenTranscriptText.nonBlank(artifact.patch) != nil
    }

    /// Whether a disclosure has something to reveal: the explanation
    /// (``explanation(of:)``, passed in) or the evidence of a diff.
    static func canExpand(_ artifact: FileChangeArtifact, explanation: String?) -> Bool {
        explanation != nil || hasDiffEvidence(artifact)
    }
}

/// The disclosure chevron of a file artifact, or a placeholder of the same
/// width when nothing can expand, so the icons stay aligned.
struct ZenFileArtifactDisclosure: View {
    let canExpand: Bool
    let isExpanded: Bool

    var body: some View {
        if canExpand {
            ZenDisclosureChevron(isExpanded: isExpanded)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }
}

/// The status icon of a file artifact, in its color.
struct ZenFileArtifactStatusIcon: View {
    let status: FileChangeArtifact.Status

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Image(systemName: ZenFileArtifactPresentation.icon(for: status))
            .foregroundStyle(ZenFileArtifactPresentation.iconColor(for: status, in: palette))
    }
}

/// What the disclosure of a file artifact reveals: its explanation, then the
/// diff its evidence establishes (``ZenFileChangeFormatting/artifactDiff(_:)``),
/// computed only while it shows.
struct ZenFileArtifactDetails: View {
    let artifact: FileChangeArtifact
    /// The explanation (``ZenFileArtifactPresentation/explanation(of:)``).
    let explanation: String?

    @Environment(\.zenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let explanation {
                Text(ZenTranscriptText.bounded(explanation, limit: 4_000))
                    .font(.callout)
                    .foregroundStyle(palette.textSecondary)
                    .textSelection(.enabled)
            }
            switch ZenFileChangeFormatting.artifactDiff(artifact) {
            case let .hunks(hunks):
                ZenDiffRowsView(hunks: hunks)
            case let .patch(lines):
                ZenPatchLinesView(lines: lines)
            case nil:
                EmptyView()
            }
        }
    }
}

/// The `/artifacts` history: one titled group per turn.
struct ZenFileArtifactsHistoryView: View {
    let turns: [SessionFileArtifactHistory.Turn]

    @Environment(\.zenPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("🪬 Artifacts")
                .font(ZenFonts.monoSmall.weight(.bold))
                .foregroundStyle(palette.fileSummaryHeader)
            if turns.isEmpty {
                Text("No file artifacts in this session.")
                    .font(.callout)
                    .foregroundStyle(palette.systemMessage)
            }
            ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                ZenFileArtifactsView(turn: turn, agentID: nil, title: "Turn \(turn.number)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("File artifacts") {
    let turn = SessionFileArtifactHistory.Turn(number: 3, artifacts: [
        FileChangeArtifact(
            absolutePath: "/tmp/project/Sources/App.swift",
            displayPath: "Sources/App.swift",
            status: .modified,
            additions: 1,
            deletions: 1,
            oldText: "let a = 1\nlet b = 2\nlet c = 3\n",
            newText: "let a = 1\nlet b = 20\nlet c = 3\n",
            explanation: "Raised the default."
        ),
        FileChangeArtifact(
            absolutePath: "/tmp/project/README.md",
            displayPath: "README.md",
            status: .added,
            additions: 2,
            newText: "# Project\nNotes\n"
        ),
        FileChangeArtifact(
            absolutePath: "/tmp/project/old.txt",
            displayPath: "old.txt",
            status: .deleted,
            hasLineCounts: false
        )
    ])
    VStack(alignment: .leading, spacing: 16) {
        ZenFileArtifactsView(turn: turn, agentID: nil)
        ZenFileArtifactsView(turn: turn, agentID: "agent_132dd052")
    }
    .padding()
    .frame(width: 560)
}
