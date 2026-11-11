//
//  ZenUserPromptView.swift
//  ZenApp
//
//  The prompt block of a turn, like the terminal's prompt block.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// The operator's prompt: a full-width rounded block on the prompt surface
/// with the text, the attachments (``ZenAttachmentPreviewView``: each image
/// shown small, each video as a chip), and a small badge naming the channel
/// when the prompt did not come from the app. It has no marker: the
/// disclosure chevron marks only the rows that expand.
public struct ZenUserPromptView: View {
    private let text: String
    private let attachments: [AgentRuntimeAttachment]
    private let origin: ChatTurnOrigin

    @State private var isShowingFullText = false
    @Environment(\.zenPalette) private var palette

    /// - Parameters:
    ///   - text: The prompt as the operator wrote it, shown as plain text.
    ///   - attachments: The files attached to the prompt.
    ///   - origin: The channel the prompt came from; `.app` shows no badge.
    public init(text: String, attachments: [AgentRuntimeAttachment], origin: ChatTurnOrigin) {
        self.text = text
        self.attachments = attachments
        self.origin = origin
    }

    public var body: some View {
        let isLong = text.utf8.count > ZenTranscriptText.longTextLimit
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isShowingFullText || !isLong
                    ? text
                    : ZenTranscriptText.bounded(text, limit: ZenTranscriptText.longTextLimit))
                    .foregroundStyle(palette.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLong {
                    Button(isShowingFullText ? "Show less" : "Show full prompt") {
                        isShowingFullText.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(palette.accentCount)
                }
                if !attachments.isEmpty {
                    ZenFlowLayout(spacing: 8) {
                        ForEach(Array(attachments.enumerated()), id: \.offset) { _, attachment in
                            ZenAttachmentPreviewView(attachment: attachment)
                        }
                    }
                }
            }
            if let badge = ZenTranscriptText.originBadge(for: origin) {
                ZenOriginBadgeView(badge: badge)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.promptBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// One attachment of a prompt without a preview: its icon and file name.
struct ZenAttachmentChip: View {
    let attachment: AgentRuntimeAttachment

    @Environment(\.zenPalette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: attachment.kind == .video ? "film" : "photo")
                .foregroundStyle(palette.accentCount)
            Text(ZenTranscriptText.inline(attachment.originalFilename, limit: 80) ?? "attachment")
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.textMuted.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(palette.turnSeparator.opacity(0.5)))
        .help(attachment.fileURL?.path ?? attachment.originalFilename)
    }
}

/// The badge of a prompt that came from another channel.
struct ZenOriginBadgeView: View {
    let badge: ZenOriginBadge

    @Environment(\.zenPalette) private var palette

    var body: some View {
        Label(badge.title, systemImage: badge.systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(palette.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(palette.textMuted.opacity(0.5)))
            .fixedSize()
    }
}

#Preview("Prompt") {
    VStack(spacing: 12) {
        ZenUserPromptView(
            text: "Refactor the transcript list so tool calls collapse by default.",
            attachments: [
                AgentRuntimeAttachment(kind: .image, originalFilename: "screenshot.png"),
                AgentRuntimeAttachment(kind: .video, originalFilename: "recording.mov")
            ],
            origin: .app
        )
        ZenUserPromptView(text: "What changed in the last turn?", attachments: [], origin: .telegram)
        ZenUserPromptView(text: "Restored prompt", attachments: [], origin: .unknown)
    }
    .padding()
    .frame(width: 560)
}
