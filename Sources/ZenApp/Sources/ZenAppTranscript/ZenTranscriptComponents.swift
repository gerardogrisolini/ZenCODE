//
//  ZenTranscriptComponents.swift
//  ZenApp
//
//  Building blocks shared by the transcript views: styled text runs, the
//  streaming indicator, status glyphs, bounded code, diff, patch, and output
//  blocks, and a wrapping layout for chips.
//

import Foundation
import SwiftUI
import ZenAppTheme

// MARK: - Styled text

/// A run of text in one palette color, joined with others into one `Text`.
struct ZenTextRun {
    let text: String
    let color: Color
    var isBold = false
    var isItalic = false
}

extension AttributedString {
    /// The runs as one attributed string, each in its color.
    static func zen(_ runs: [ZenTextRun]) -> AttributedString {
        var output = AttributedString()
        for run in runs {
            var part = AttributedString(run.text)
            part.foregroundColor = run.color
            var intent: InlinePresentationIntent = []
            if run.isBold { intent.insert(.stronglyEmphasized) }
            if run.isItalic { intent.insert(.emphasized) }
            if !intent.isEmpty {
                part.inlinePresentationIntent = intent
            }
            output.append(part)
        }
        return output
    }
}

/// The runs of an overview summary line, with ` ` between the segments.
func zenSummaryRuns(_ segments: [ZenStatusSegment], palette: ZenPalette) -> [ZenTextRun] {
    var runs: [ZenTextRun] = []
    for (index, segment) in segments.enumerated() {
        if index > 0 {
            runs.append(ZenTextRun(text: "  ", color: palette.textMuted))
        }
        runs.append(ZenTextRun(
            text: segment.text,
            color: segment.role?.color(in: palette) ?? palette.textMuted
        ))
    }
    return runs
}

// MARK: - Indicators

/// The subtle accent indicator of a text that is still streaming.
struct ZenStreamingIndicator: View {
    var color: Color?

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Image(systemName: "ellipsis")
            .font(.callout.weight(.semibold))
            .foregroundStyle(color ?? palette.accent)
            .symbolEffect(.variableColor.iterative, options: .repeat(.continuous))
            .accessibilityLabel("Streaming")
    }
}

/// The status glyph of a compact tool line: a pulsing dot while the call
/// runs, then `✓`, `✗`, or `⊘` in the status color.
struct ZenToolStatusGlyph: View {
    let status: ZenToolCallStatus

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Group {
            if status == .running {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .symbolEffect(.pulse, options: .repeat(.continuous))
            } else {
                Text(status.glyph)
                    .fontWeight(.bold)
            }
        }
        .foregroundStyle(status.role.color(in: palette))
        .frame(width: 14, alignment: .center)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        switch status {
        case .running: "Running"
        case .completed: "Completed"
        case .failed: "Failed"
        case .permissionDenied: "Permission denied"
        }
    }
}

/// A disclosure chevron that turns down when expanded.
struct ZenDisclosureChevron: View {
    let isExpanded: Bool

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.bold))
            .foregroundStyle(palette.textMuted)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
    }
}

/// The "Show N more lines" / "Show less" toggle of a bounded block.
struct ZenShowMoreButton: View {
    let hiddenLineCount: Int
    @Binding var isShowingAll: Bool

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Button {
            isShowingAll.toggle()
        } label: {
            Text(isShowingAll
                ? "Show less"
                : "Show \(hiddenLineCount) more line\(hiddenLineCount == 1 ? "" : "s")")
                .font(.caption.weight(.medium))
                .foregroundStyle(palette.accentCount)
        }
        .buttonStyle(.plain)
    }
}

/// A thin rule in the palette's separator color (`Divider` uses the system one).
struct ZenSeparator: View {
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.turnSeparator.opacity(0.5))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}

/// A small label above a detail block (`toolLabel`).
struct ZenDetailLabel: View {
    let text: String

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(palette.toolLabel)
    }
}

// MARK: - Blocks

/// The surface of a content card of the transcript (file-change summary,
/// task graph, sub-agents): a rounded `surface` fill with a `turnSeparator`
/// border. Content inside the scroll view never uses Liquid Glass, which
/// stays on the controls (composer, consent sheet, suggestions, buttons).
///
/// The fill is a translucent `surface`, so the code, diff, and patch blocks
/// drawn on the opaque code backgrounds stand out inside the card.
struct ZenContentCard: ViewModifier {
    let cornerRadius: CGFloat
    let padding: CGFloat

    @Environment(\.zenPalette) private var palette

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .padding(padding)
            .background(palette.surface.opacity(0.55), in: shape)
            .overlay {
                shape
                    .strokeBorder(palette.turnSeparator.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Draws the view on a transcript content card (``ZenContentCard``).
    func zenContentCard(cornerRadius: CGFloat = 14, padding: CGFloat = 12) -> some View {
        modifier(ZenContentCard(cornerRadius: cornerRadius, padding: padding))
    }
}

/// The monospaced surface of code, diff, patch, and output blocks.
struct ZenCodeSurface: ViewModifier {
    @Environment(\.zenPalette) private var palette

    func body(content: Content) -> some View {
        content
            .font(ZenFonts.monoSmall)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.toolCodeBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .textSelection(.enabled)
    }
}

extension View {
    func zenCodeSurface() -> some View {
        modifier(ZenCodeSurface())
    }
}

/// A line number right-aligned to `width` digits.
func zenGutter(_ number: Int?, width: Int) -> String {
    let text = number.map(String.init) ?? ""
    return String(repeating: " ", count: max(0, width - text.count)) + text
}

/// Source lines with `codeGutter` line numbers on the code background,
/// bounded with a "Show more" toggle.
struct ZenCodeLinesView: View {
    let content: String

    @State private var isShowingAll = false
    @Environment(\.zenPalette) private var palette

    var body: some View {
        let limit = isShowingAll
            ? ZenToolCallFormatting.diffLineLimit
            : ZenToolCallFormatting.codePreviewLineLimit
        let bounded = ZenTranscriptText.boundedLines(content, maxLines: limit)
        let width = String(max(1, bounded.lines.count)).count
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(bounded.lines.enumerated()), id: \.offset) { index, line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(zenGutter(index + 1, width: width))
                            .foregroundStyle(palette.codeGutter)
                        Text(line)
                            .foregroundStyle(palette.codeForeground)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 8)
                }
            }
            .zenCodeSurface()
            if bounded.isTruncated || isShowingAll {
                ZenShowMoreButton(hiddenLineCount: bounded.hiddenLineCount, isShowingAll: $isShowingAll)
            }
        }
    }
}

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

/// The lines of a unified patch: hunk headers in `fileHunk`, file headers in
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
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, line in
                    lineText(line)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .background(background(line.kind))
                }
            }
            .zenCodeSurface()
            if hidden > 0 || isShowingAll {
                ZenShowMoreButton(hiddenLineCount: hidden, isShowingAll: $isShowingAll)
            }
        }
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

/// A tool's output on the code background, bounded to the preview lines with
/// a "Show more" toggle; a failure is written in `failureMessage`.
struct ZenToolOutputView: View {
    let output: String
    let isFailure: Bool

    @State private var isShowingAll = false
    @Environment(\.zenPalette) private var palette

    var body: some View {
        let limit = isShowingAll
            ? ZenToolCallFormatting.outputExpandedLineLimit
            : ZenToolCallFormatting.outputPreviewLineLimit
        let bounded = ZenTranscriptText.boundedLines(output, maxLines: limit)
        VStack(alignment: .leading, spacing: 4) {
            Text(bounded.text)
                .foregroundStyle(isFailure ? palette.failureMessage : palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .zenCodeSurface()
            if bounded.isTruncated || isShowingAll {
                ZenShowMoreButton(hiddenLineCount: bounded.hiddenLineCount, isShowingAll: $isShowingAll)
            }
        }
    }
}

// MARK: - Layout

/// Places its subviews left to right, wrapping to a new row when the width
/// runs out (attachments).
struct ZenFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            size.width = min(size.width, maxWidth)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, proposedWidth > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
            current.sizes.append(size)
        }
        if !current.indices.isEmpty {
            rows.append(current)
        }
        return rows
    }
}
