//
//  ZenTranscriptDiffViews.swift
//  ZenApp
//
//  The line-diff and unified-patch blocks of the transcript: numbered rows with
//  the change markers, the diff colors, and the language highlighting.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// Which line numbers the rows of a line diff show.
enum ZenDiffLineNumbers: Sendable, Equatable {
    /// The old and the new line number, in two columns (the tool calls).
    case oldAndNew
    /// One column, as the terminal's file artifacts: the old line of a
    /// deletion, the new line of an addition or a context line.
    case source
}

/// The rows of a line diff: the line numbers in `codeGutter` (old and new, or
/// the source column of ``ZenDiffLineNumbers/source``), the `+`/`−` marker
/// in the file-change colors, and the line on the diff background of its
/// kind. With a language, the environment's ``ZenCodeHighlighter`` colors
/// the source of every line, as the terminal does.
struct ZenDiffRowsView: View {
    let hunks: [[ZenTranscriptDiffRow]]
    /// The language of the source lines
    /// (``ZenFileChangeFormatting/sourceLanguage(of:)``); `nil` leaves them to
    /// the colors of their kind.
    let language: String?
    let lineNumbers: ZenDiffLineNumbers

    @State private var isShowingAll = false
    @Environment(\.zenPalette) private var palette
    @Environment(\.zenCodeHighlighter) private var highlighter

    init(rows: [ZenTranscriptDiffRow]) {
        self.init(hunks: [rows])
    }

    init(
        hunks: [[ZenTranscriptDiffRow]],
        language: String? = nil,
        lineNumbers: ZenDiffLineNumbers = .oldAndNew
    ) {
        self.hunks = hunks
        self.language = language
        self.lineNumbers = lineNumbers
    }

    var body: some View {
        let limit = isShowingAll
            ? ZenToolCallFormatting.diffLineLimit
            : ZenToolCallFormatting.codePreviewLineLimit
        let (visible, hidden) = Self.bounded(hunks, limit: limit)
        let width = Self.gutterWidth(visible, lineNumbers: lineNumbers)
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { hunkIndex, hunk in
                    if hunkIndex > 0 {
                        Text("⋯")
                            .foregroundStyle(palette.fileHunk)
                            .padding(.horizontal, 8)
                    }
                    ForEach(Array(hunk.enumerated()), id: \.offset) { _, row in
                        diffRow(row, width: width)
                    }
                }
            }
            .zenCodeSurface()
            if hidden > 0 || isShowingAll {
                ZenShowMoreButton(hiddenLineCount: hidden, isShowingAll: $isShowingAll)
            }
        }
    }

    private func diffRow(_ row: ZenTranscriptDiffRow, width: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            switch lineNumbers {
            case .oldAndNew:
                Text(zenGutter(row.oldLineNumber, width: width))
                    .foregroundStyle(palette.codeGutter)
                Text(zenGutter(row.newLineNumber, width: width))
                    .foregroundStyle(palette.codeGutter)
            case .source:
                Text(zenGutter(Self.sourceLineNumber(of: row), width: width))
                    .foregroundStyle(palette.codeGutter)
            }
            Text(marker(row.kind))
                .foregroundStyle(markerColor(row.kind))
            lineText(row)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .background(background(row.kind))
    }

    /// The line, colored by the highlighter in the diff's language, else in
    /// the color of its kind.
    private func lineText(_ row: ZenTranscriptDiffRow) -> Text {
        let text = ZenTranscriptText.bounded(row.text, limit: 1_000)
        if let language, let highlighted = highlighter.highlight(text, language: language, palette: palette) {
            return Text(highlighted)
        }
        return Text(text).foregroundStyle(textColor(row.kind))
    }

    /// The line number of the source column (``ZenDiffLineNumbers/source``):
    /// the old line of a deletion, the new line of an addition or a context
    /// line, as the terminal's file artifacts number them.
    static nonisolated func sourceLineNumber(of row: ZenTranscriptDiffRow) -> Int? {
        row.kind == .deletion ? row.oldLineNumber : row.newLineNumber
    }

    /// The digits of the widest line number the rows show (at least one).
    static nonisolated func gutterWidth(_ hunks: [[ZenTranscriptDiffRow]], lineNumbers: ZenDiffLineNumbers) -> Int {
        let widest = hunks.joined().reduce(1) { result, row in
            switch lineNumbers {
            case .oldAndNew:
                max(result, row.oldLineNumber ?? 0, row.newLineNumber ?? 0)
            case .source:
                max(result, sourceLineNumber(of: row) ?? 0)
            }
        }
        return String(widest).count
    }

    private func marker(_ kind: ZenTranscriptDiffRow.Kind) -> String {
        switch kind {
        case .context: " "
        case .addition: "+"
        case .deletion: "−"
        }
    }

    private func markerColor(_ kind: ZenTranscriptDiffRow.Kind) -> Color {
        switch kind {
        case .context: palette.codeGutter
        case .addition: palette.fileAddition
        case .deletion: palette.fileDeletion
        }
    }

    private func textColor(_ kind: ZenTranscriptDiffRow.Kind) -> Color {
        switch kind {
        case .context: palette.codeForeground
        case .addition: palette.diffAddition
        case .deletion: palette.diffRemoval
        }
    }

    private func background(_ kind: ZenTranscriptDiffRow.Kind) -> Color {
        switch kind {
        case .context: .clear
        case .addition: palette.diffAdditionBackground
        case .deletion: palette.diffRemovalBackground
        }
    }

    /// The hunks cut to `limit` rows in total, and the count of the rows cut.
    static func bounded(
        _ hunks: [[ZenTranscriptDiffRow]],
        limit: Int
    ) -> ([[ZenTranscriptDiffRow]], Int) {
        var remaining = limit
        var visible: [[ZenTranscriptDiffRow]] = []
        var hidden = 0
        for hunk in hunks {
            guard remaining > 0 else {
                hidden += hunk.count
                continue
            }
            let kept = Array(hunk.prefix(remaining))
            visible.append(kept)
            hidden += hunk.count - kept.count
            remaining -= kept.count
        }
        return (visible, hidden)
    }
}

/// The lines of a unified patch, numbered in one `codeGutter` column as the
/// terminal's file artifacts number them
/// (``ZenFileChangeFormatting/patchLineNumbers(_:)``: the old line of a removed
/// line, the new line of an added or context line, none for headers, notes,
/// and lines outside a hunk): hunk headers in `fileHunk`, file headers in
/// `fileMetadata`, and `+`/`−` lines in the palette's diff colors. With a
/// language, the environment's ``ZenCodeHighlighter`` colors the source after
/// the marker of the lines that carry source, as the terminal does.
struct ZenPatchLinesView: View {
    let lines: [ZenPatchLine]
    /// The language of the source lines
    /// (``ZenFileChangeFormatting/sourceLanguage(of:)``); `nil` leaves them to
    /// the colors of their kind.
    var language: String? = nil

    @State private var isShowingAll = false
    @Environment(\.zenPalette) private var palette
    @Environment(\.zenCodeHighlighter) private var highlighter

    var body: some View {
        let limit = isShowingAll
            ? ZenToolCallFormatting.diffLineLimit
            : ZenFileChangeFormatting.patchPreviewLineLimit
        let visible = lines.prefix(limit)
        let hidden = lines.count - visible.count
        // The numbering is sequential, so the visible prefix numbers as it
        // does within the whole patch.
        let numbers = ZenFileChangeFormatting.patchLineNumbers(Array(visible))
        let width = Self.gutterWidth(numbers)
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                    patchRow(line, number: numbers[index], width: width)
                }
            }
            .zenCodeSurface()
            if hidden > 0 || isShowingAll {
                ZenShowMoreButton(hiddenLineCount: hidden, isShowingAll: $isShowingAll)
            }
        }
    }

    private func patchRow(_ line: ZenPatchLine, number: Int?, width: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(zenGutter(number, width: width))
                .foregroundStyle(palette.codeGutter)
            lineText(line)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 8)
        .background(background(line.kind))
    }

    /// The digits of the widest of `numbers` (at least one), as
    /// ``ZenDiffRowsView/gutterWidth(_:lineNumbers:)`` sizes its gutter.
    static nonisolated func gutterWidth(_ numbers: [Int?]) -> Int {
        String(numbers.reduce(1) { max($0, $1 ?? 0) }).count
    }

    /// The line: the marker in the color of its kind and the source colored
    /// by the highlighter in the patch's language, else the whole line in the
    /// color of its kind.
    private func lineText(_ line: ZenPatchLine) -> Text {
        if let language, let parts = ZenFileChangeFormatting.patchSource(of: line),
           let highlighted = highlighter.highlight(
               ZenTranscriptText.bounded(parts.source, limit: 1_000),
               language: language,
               palette: palette
           ) {
            var text = AttributedString(parts.marker)
            text.swiftUI.foregroundColor = color(line.kind)
            text.append(highlighted)
            return Text(text)
        }
        return Text(ZenTranscriptText.bounded(line.text, limit: 1_000))
            .foregroundStyle(color(line.kind))
    }

    private func color(_ kind: ZenPatchLine.Kind) -> Color {
        switch kind {
        case .hunk: palette.fileHunk
        case .header, .note: palette.fileMetadata
        case .addition: palette.diffAddition
        case .deletion: palette.diffRemoval
        case .context: palette.codeForeground
        }
    }

    private func background(_ kind: ZenPatchLine.Kind) -> Color {
        switch kind {
        case .addition: palette.diffAdditionBackground
        case .deletion: palette.diffRemovalBackground
        case .hunk, .header, .note, .context: .clear
        }
    }
}
