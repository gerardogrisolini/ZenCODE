//
//  ZenTranscriptComponents.swift
//  ZenApp
//
//  Building blocks shared by the transcript views: styled text runs, the
//  streaming indicator, status glyphs, and bounded code and output blocks.
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
