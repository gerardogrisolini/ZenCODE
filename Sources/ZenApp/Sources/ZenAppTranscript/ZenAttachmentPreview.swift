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
import ImageIO
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
    @State private var thumbnail: NSImage?
    @Environment(\.zenPalette) private var palette

    var body: some View {
        Group {
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
        .task {
            guard attachment.kind == .image else { return }
            let image = await Self.thumbnail(of: attachment)
            guard !Task.isCancelled, let image else { return }
            thumbnail = NSImage(
                cgImage: image,
                size: NSSize(width: image.width, height: image.height)
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail {
            let size = Self.fittedSize(thumbnail.size)
            Image(nsImage: thumbnail)
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
    nonisolated static func fileURL(of attachment: AgentRuntimeAttachment) -> URL? {
        guard let url = attachment.fileURL, url.isFileURL else {
            return nil
        }
        return url
    }

    /// The thumbnail of an image attachment, decoded and downsampled away
    /// from the caller's actor. Bytes take precedence, with the local file as
    /// a fallback when they cannot be decoded. The maximum pixel dimension is
    /// twice the largest preview dimension, enough for a Retina display.
    @concurrent
    nonisolated static func thumbnail(
        of attachment: AgentRuntimeAttachment,
        maxPixelSize: Int = 640
    ) async -> CGImage? {
        guard attachment.kind == .image else { return nil }
        if let data = attachment.data, let image = thumbnail(data: data, maxPixelSize: maxPixelSize) {
            return image
        }
        guard let url = fileURL(of: attachment) else { return nil }
        return thumbnail(file: url, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func thumbnail(data: Data, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func thumbnail(file: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return thumbnail(source: source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func thumbnail(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
