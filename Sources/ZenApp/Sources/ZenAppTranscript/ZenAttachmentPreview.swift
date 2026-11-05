//
//  ZenAttachmentPreview.swift
//  ZenApp
//
//  An attachment of a prompt in the prompt block: an image shown small, a
//  video as its chip. A click shows the attachment in Quick Look: its file
//  when it exists, else its bytes through a private temporary copy that is
//  removed when Quick Look closes.
//

import AppKit
import Foundation
import QuickLook
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// Where Quick Look shows an attachment from.
enum ZenAttachmentQuickLookSource: Equatable {
    /// The local file of the attachment, which exists.
    case file(URL)
    /// The bytes of the attachment, shown through a private temporary copy.
    case bytes(Data)
}

/// An attachment of a prompt: an image shown small, from its bytes or else
/// its file; a video, or an image that cannot be read, as its chip. A click
/// shows the attachment, image or video, in Quick Look: from its local file
/// when it exists, else from its bytes through a private temporary copy that
/// is removed when Quick Look closes. Without either the attachment is not
/// clickable.
struct ZenAttachmentPreviewView: View {
    /// The largest size of an image, in points.
    static let maximumSize = CGSize(width: 320, height: 200)

    let attachment: AgentRuntimeAttachment

    @State private var quickLookURL: URL?
    /// The temporary copy of the bytes that Quick Look shows, if any.
    @State private var temporaryURL: URL?
    @Environment(\.zenPalette) private var palette

    var body: some View {
        if Self.quickLookSource(of: attachment) != nil {
            Button {
                open()
            } label: {
                content
            }
            .buttonStyle(.plain)
            .accessibilityHint(attachment.kind == .video
                ? "Plays the video in Quick Look"
                : "Shows the image larger in Quick Look")
            .quickLookPreview($quickLookURL)
            .onChange(of: quickLookURL) { _, url in
                // Quick Look closed, or shows another file.
                if url != temporaryURL {
                    discardTemporaryFile()
                }
            }
            .onDisappear {
                discardTemporaryFile()
            }
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

    /// Shows the attachment in Quick Look: its file, or else a private
    /// temporary copy of its bytes. Nothing happens when the copy cannot be
    /// written.
    private func open() {
        switch Self.quickLookSource(of: attachment) {
        case .file(let url):
            quickLookURL = url
        case .bytes(let data):
            discardTemporaryFile()
            guard let url = try? ZenQuickLookTemporaryFile.write(
                data,
                filename: ZenQuickLookTemporaryFile.filename(for: attachment)
            ) else {
                return
            }
            temporaryURL = url
            quickLookURL = url
        case nil:
            break
        }
    }

    /// Removes the temporary copy shown in Quick Look, if any.
    private func discardTemporaryFile() {
        guard let url = temporaryURL else {
            return
        }
        ZenQuickLookTemporaryFile.remove(url)
        temporaryURL = nil
    }

    // MARK: - Rules

    /// Where Quick Look shows `attachment` from: its local file when it exists
    /// and is not a directory, else its bytes when it has any, else `nil`.
    /// The same for an image and a video.
    static func quickLookSource(of attachment: AgentRuntimeAttachment) -> ZenAttachmentQuickLookSource? {
        if let url = fileURL(of: attachment) {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return .file(url)
            }
        }
        if let data = attachment.data, !data.isEmpty {
            return .bytes(data)
        }
        return nil
    }

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
