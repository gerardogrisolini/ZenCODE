//
//  ZenFileArtifactPresentation.swift
//  ZenApp
//
//  The presentation the sidebar's artifact cards share: the status icon, the
//  disclosure, and what it reveals (explanation and diff).
//

import Foundation
import SwiftUI
import ToolCore
import ZenAppTheme

/// The presentation a file artifact's sidebar card shares with its parts: the
/// status icon and its color, and what a disclosure can reveal.
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
/// computed only while it shows. As in the terminal, the diff numbers its
/// lines in one column and colors the source in the file's language
/// (``ZenFileChangeFormatting/sourceLanguage(of:)``).
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
            let language = ZenFileChangeFormatting.sourceLanguage(of: artifact)
            switch ZenFileChangeFormatting.artifactDiff(artifact) {
            case let .hunks(hunks):
                ZenDiffRowsView(hunks: hunks, language: language, lineNumbers: .source)
            case let .patch(lines):
                ZenPatchLinesView(lines: lines, language: language)
            case nil:
                EmptyView()
            }
        }
    }
}
