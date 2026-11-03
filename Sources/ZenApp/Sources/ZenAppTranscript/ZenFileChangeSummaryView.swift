//
//  ZenFileChangeSummaryView.swift
//  ZenApp
//
//  The file-change summary of a turn, like the terminal's summary.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The file-change summary card of a turn: the header with the file count
/// and the line totals, one row per file with its counts (or binary
/// marker), an expandable patch per file, and the `/undo` hint.
public struct ZenFileChangeSummaryView: View {
    private let summary: TurnFileChangeSummary
    private let includesDiff: Bool

    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - summary: The summary of the turn.
    ///   - includesDiff: `true` when the patches were asked for
    ///     (`/changes diff`): they start expanded. Otherwise they start
    ///     collapsed and each file can still expand its own.
    public init(summary: TurnFileChangeSummary, includesDiff: Bool) {
        self.summary = summary
        self.includesDiff = includesDiff
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(AttributedString.zen([
                ZenTextRun(text: "🪬 Summary: ", color: palette.fileSummaryHeader, isBold: true),
                ZenTextRun(text: "\(summary.fileCount)", color: palette.fileCount, isBold: true),
                ZenTextRun(
                    text: summary.fileCount == 1 ? " file changed" : " files changed",
                    color: palette.filePath
                ),
                ZenTextRun(text: "  +\(summary.totalAdditions)", color: palette.fileAddition),
                ZenTextRun(text: " −\(summary.totalDeletions)", color: palette.fileDeletion)
            ]))
            .font(ZenFonts.monoSmall)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(summary.entries) { entry in
                    ZenFileChangeEntryRow(entry: entry, initiallyExpanded: includesDiff)
                }
            }

            hint
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .zenContentCard(cornerRadius: 14)
    }

    private var hint: some View {
        let text = ZenFileChangeFormatting.hintText(summary)
        var runs: [ZenTextRun] = []
        var remaining = Substring(text)
        // The command tokens keep the count color, as in the terminal.
        while let range = ["/undo", "/changes diff"]
            .compactMap({ remaining.range(of: $0) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            runs.append(ZenTextRun(text: String(remaining[..<range.lowerBound]), color: palette.fileHint))
            runs.append(ZenTextRun(text: String(remaining[range]), color: palette.fileCount))
            remaining = remaining[range.upperBound...]
        }
        runs.append(ZenTextRun(text: String(remaining), color: palette.fileHint))
        return Text(AttributedString.zen(runs))
            .font(.caption)
    }
}

/// One file of a summary: status, path, counts, and its patch.
struct ZenFileChangeEntryRow: View {
    let entry: TurnFileChangeSummary.Entry

    @State private var isExpanded: Bool
    @Environment(\.zenPalette) private var palette

    init(entry: TurnFileChangeSummary.Entry, initiallyExpanded: Bool) {
        self.entry = entry
        _isExpanded = State(initialValue: initiallyExpanded && ZenTranscriptText.nonBlank(entry.patch) != nil)
    }

    var body: some View {
        let patch = entry.isBinary ? nil : ZenTranscriptText.nonBlank(entry.patch)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if patch != nil {
                        ZenDisclosureChevron(isExpanded: isExpanded)
                    } else {
                        Color.clear.frame(width: 12, height: 1)
                    }
                    Text(AttributedString.zen(runs))
                        .font(ZenFonts.monoSmall)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(patch == nil)

            if isExpanded, let patch {
                ZenPatchLinesView(lines: ZenFileChangeFormatting.patchLines(patch))
                    .padding(.leading, 18)
            }
        }
    }

    private var runs: [ZenTextRun] {
        var runs = [
            ZenTextRun(text: entry.status.rawValue + " ", color: palette.fileMetadata),
            ZenTextRun(text: ZenTranscriptText.inline(entry.path, limit: 1_000) ?? entry.path, color: palette.filePath)
        ]
        if entry.isBinary {
            runs.append(ZenTextRun(text: " (binary)", color: palette.fileMetadata))
        } else {
            runs.append(ZenTextRun(text: "  +\(entry.additions)", color: palette.fileAddition))
            runs.append(ZenTextRun(text: " −\(entry.deletions)", color: palette.fileDeletion))
        }
        return runs
    }
}

#Preview("File change summary") {
    let summary = TurnFileChangeSummary(entries: [
        .init(
            path: "Sources/App/Transcript.swift",
            additions: 3,
            deletions: 1,
            status: .modified,
            isBinary: false,
            existedBefore: true,
            beforeDataBase64: nil,
            patch: "--- a/Transcript.swift\n+++ b/Transcript.swift\n@@ -1,3 +1,5 @@\n import SwiftUI\n-let old = 1\n+let new = 2\n+let more = 3\n+let extra = 4\n struct Transcript {}"
        ),
        .init(
            path: "Resources/logo.png",
            additions: 0,
            deletions: 0,
            status: .added,
            isBinary: true,
            existedBefore: false,
            beforeDataBase64: nil,
            patch: nil
        )
    ])
    ZenFileChangeSummaryView(summary: summary, includesDiff: true)
        .padding()
        .frame(width: 560)
}
