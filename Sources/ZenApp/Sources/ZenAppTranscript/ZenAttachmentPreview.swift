//
//  ZenAttachmentPreview.swift
//  ZenApp
//
//  An attachment of a prompt in the prompt block: an image shown small, a
//  video as its chip. A click opens the image in its default application and
//  plays the video in Quick Look.
//

import AppKit
import Foundation
import QuickLook
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// An attachment of a prompt: an image shown small, from its bytes or else
/// its file; a video, or an image that cannot be read, as its chip. A click
/// opens the image in its default application and plays the video in Quick
/// Look; without a local file the attachment is not clickable.
struct ZenAttachmentPreviewView: View {
    /// The largest size of an image, in points.
    static let maximumSize = CGSize(width: 320, height: 200)

    let attachment: AgentRuntimeAttachment

    @State private var quickLookURL: URL?
    @Environment(\.openURL) private var openURL
    @Environment(\.zenPalette) private var palette

    var body: some View {
        if let url = Self.fileURL(of: attachment) {
            Button {
                open(url)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint(attachment.kind == .video
                ? "Plays the video in Quick Look"
                : "Opens the image in its default application")
            .quickLookPreview($quickLookURL)
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = Self.image(of: attachment) {
            let size = Self.fittedSize(image.size)
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(palette.turnSeparator.opacity(0.5))
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .help(attachment.fileURL?.path(percentEncoded: false) ?? attachment.originalFilename)
                .accessibilityElement()
                .accessibilityLabel("Image \(ZenTranscriptText.inline(attachment.originalFilename, limit: 80) ?? "attachment")")
                .accessibilityAddTraits(.isImage)
        } else {
            ZenAttachmentChip(attachment: attachment)
        }
    }

    private func open(_ url: URL) {
        switch attachment.kind {
        case .image:
            openURL(url)
        case .video:
            quickLookURL = url
        }
    }

    // MARK: - Rules

    /// The local file of `attachment`, if it has one.
    static func fileURL(of attachment: AgentRuntimeAttachment) -> URL? {
        guard let url = attachment.fileURL, url.isFileURL else {
            return nil
        }
        return url
    }

    /// The image of an image attachment: from its bytes, or else from its
    /// file. `nil` for a video, or when neither can be read.
    static func image(of attachment: AgentRuntimeAttachment) -> NSImage? {
        guard attachment.kind == .image else {
            return nil
        }
        if let data = attachment.data, let image = NSImage(data: data) {
            return image
        }
        return fileURL(of: attachment).flatMap(NSImage.init(contentsOf:))
    }

    /// `size` scaled down to fit `bounds`, keeping its proportions; a size
    /// that fits already is kept as it is. `.zero` for an empty size.
    static func fittedSize(_ size: CGSize, in bounds: CGSize = maximumSize) -> CGSize {
        guard size.width > 0, size.height > 0 else {
            return .zero
        }
        let scale = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(
            width: max(1, (size.width * scale).rounded()),
            height: max(1, (size.height * scale).rounded())
        )
    }
}
