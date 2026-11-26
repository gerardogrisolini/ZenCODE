//
//  ZenCODEACPBridge+Attachments.swift
//  ZenCODE
//

import Foundation
import ToolCore
import ZenCODERuntime

/// What a prompt's blocks point at, before anything is read: the attachments
/// carried inline and the files to read. `Sendable`, so the parsing can happen
/// on the bridge and the reading elsewhere.
public struct ACPPromptAttachmentPlan: Sendable {
    public var attachments: [AgentRuntimeAttachment] = []
    public var files: [ACPAttachmentFile] = []
    /// The session's working directory: the only place beside the system
    /// temporary directories an attachment file may be read from.
    public var workingDirectory: String = ""
}

/// A file an ACP prompt points at, with the type the request declares for it.
public struct ACPAttachmentFile: Sendable {
    public let url: URL
    public let contentType: String?
}

extension ZenCODEACPBridge {
    /// The most one attachment of a `session/prompt` may carry. A request is
    /// the client's, so the agent bounds what it reads and forwards: an
    /// attachment of any size would otherwise be loaded into memory and sent to
    /// the provider.
    static let maximumAttachmentBytes = 20 * 1024 * 1024

    public func promptBlocks(from params: [String: Any]) -> [Any] {
        if let prompt = params["prompt"] as? [Any] {
            return prompt
        }
        if let content = params["content"] as? [Any] {
            return content
        }
        if let prompt = params["prompt"] as? String {
            return [
                [
                    "type": "text",
                    "text": prompt
                ] as [String: Any]
            ]
        }
        if let content = params["content"] as? String {
            return [
                [
                    "type": "text",
                    "text": content
                ] as [String: Any]
            ]
        }
        return []
    }

    /// The attachments of the prompt's blocks: what the request carries is
    /// parsed here, synchronously, and the files it points at are listed for the
    /// caller to read off the bridge's actor (see ``readAttachments(of:)``). A
    /// prompt block is not `Sendable`, so only the resulting plan is handed to
    /// the reading step.
    public static func attachmentPlan(
        from blocks: [Any],
        renderedPromptText _: String,
        cwd: String
    ) -> ACPPromptAttachmentPlan {
        var plan = ACPPromptAttachmentPlan()
        plan.workingDirectory = cwd
        var seenKeys = Set<String>()

        func key(of attachment: AgentRuntimeAttachment) -> String {
            attachment.fileURL?.standardizedFileURL.path
                ?? "\(attachment.originalFilename):\(attachment.data?.count ?? 0)"
        }

        func append(_ source: ACPAttachmentSource?) {
            guard let source else {
                return
            }
            switch source {
            case let .data(data, contentType, originalFilename):
                guard data.count <= maximumAttachmentBytes,
                      let kind = attachmentKind(mimeType: contentType, filename: originalFilename) else {
                    return
                }
                let attachment = AgentRuntimeAttachment(
                    kind: kind,
                    data: data,
                    contentType: contentType,
                    originalFilename: originalFilename
                        ?? embeddedAttachmentFilename(contentType: contentType)
                )
                guard seenKeys.insert(key(of: attachment)).inserted else { return }
                plan.attachments.append(attachment)
            case let .file(url, contentType):
                guard seenKeys.insert(url.standardizedFileURL.path).inserted else { return }
                plan.files.append(ACPAttachmentFile(url: url, contentType: contentType))
            }
        }

        for block in blocks {
            append(attachmentSource(from: block, cwd: cwd))
        }
        return plan
    }

    /// The attachments `plan` describes: the inline ones, then every file it
    /// names, read off the actor and bounded.
    public static func readAttachments(of plan: ACPPromptAttachmentPlan) async -> [AgentRuntimeAttachment] {
        var attachments = plan.attachments
        for file in plan.files {
            guard let attachment = await loadAttachmentFile(
                file.url,
                contentType: file.contentType,
                cwd: plan.workingDirectory
            ) else {
                continue
            }
            attachments.append(attachment)
        }
        return attachments
    }

    /// The attachments of a prompt, parsed and read in one step: the entry
    /// point of a caller that already holds the blocks on its own actor.
    public static func promptAttachments(
        from blocks: [Any],
        renderedPromptText: String,
        cwd: String
    ) async -> [AgentRuntimeAttachment] {
        await readAttachments(of: attachmentPlan(
            from: blocks,
            renderedPromptText: renderedPromptText,
            cwd: cwd
        ))
    }

    private enum ACPAttachmentSource {
        /// Bytes the request carried inline.
        case data(Data, contentType: String?, originalFilename: String?)
        /// A file the request points at.
        case file(URL, contentType: String?)
    }

    private static func attachmentSource(from block: Any, cwd: String) -> ACPAttachmentSource? {
        guard let object = block as? [String: Any] else {
            return nil
        }
        let type = stringValue(object["type"])?.lowercased() ?? "text"

        switch type {
        case "image", "input_image":
            return mediaSource(from: object, cwd: cwd)
        case "image_url":
            return urlSource(from: object["image_url"], cwd: cwd)
        case "resource":
            guard let resource = object["resource"] as? [String: Any] else {
                return nil
            }
            return mediaSource(from: resource, cwd: cwd)
        default:
            if let imageURL = object["image_url"] {
                return urlSource(from: imageURL, cwd: cwd)
            }
            return nil
        }
    }

    /// The attachment a media block names: the bytes it embeds, else the file
    /// it points at (a `data:` URL among them).
    private static func mediaSource(from object: [String: Any], cwd: String) -> ACPAttachmentSource? {
        let contentType = firstString(
            in: object,
            keys: ["mimeType", "mime_type", "mediaType", "media_type", "contentType", "content_type"]
        )
        let originalFilename = firstString(in: object, keys: ["filename", "fileName", "name", "title"])
        if let data = firstBase64Data(in: object) {
            return .data(data, contentType: contentType, originalFilename: originalFilename)
        }

        if let uri = firstString(in: object, keys: ["uri", "url", "path", "image_url"]) {
            return urlSource(from: uri, cwd: cwd, contentType: contentType)
        }
        return nil
    }

    private static func urlSource(
        from value: Any?,
        cwd: String,
        contentType: String? = nil
    ) -> ACPAttachmentSource? {
        let rawURL: String?
        if let string = value as? String {
            rawURL = string
        } else if let object = value as? [String: Any] {
            rawURL = firstString(in: object, keys: ["url", "uri", "path"])
        } else {
            rawURL = nil
        }

        guard let rawURL = rawURL?.nilIfBlank else {
            return nil
        }
        if let (mimeType, data) = imageDataURL(rawURL) {
            return .data(data, contentType: contentType ?? mimeType, originalFilename: nil)
        }
        guard let fileURL = fileURL(from: rawURL, cwd: cwd) else {
            return nil
        }
        return .file(fileURL, contentType: contentType)
    }

    /// Reads the attachment `url` names, off the bridge's actor.
    ///
    /// The file must be one the session may read (see
    /// ``isReadableAttachmentLocation(_:cwd:)``), no larger than
    /// ``maximumAttachmentBytes``, and of a media kind the request declares or
    /// its name tells: a `resource` carrying a document is not an image, and is
    /// not forwarded to the provider as one. The read is detached, so a large
    /// file or a slow disk never blocks the turn, a `session/cancel`, or the
    /// bridge's other requests.
    private static func loadAttachmentFile(
        _ url: URL,
        contentType: String?,
        cwd: String
    ) async -> AgentRuntimeAttachment? {
        guard isReadableAttachmentLocation(url, cwd: cwd) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            let standardizedURL = url.standardizedFileURL
            let declaredKind = attachmentKind(
                mimeType: contentType,
                filename: standardizedURL.lastPathComponent
            )
            // A declared type that is not media at all (a PDF, a text file) is
            // not an attachment: its text, if any, is already in the prompt.
            if contentType?.nilIfBlank != nil, declaredKind == nil {
                return nil
            }
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: standardizedURL.path
            ),
                let size = (attributes[.size] as? NSNumber)?.intValue,
                size <= maximumAttachmentBytes else {
                return nil
            }
            guard let imported = try? AgentRuntimeAttachmentStore.importFile(from: standardizedURL) else {
                return nil
            }
            let attachment = imported.runtimeAttachment
            if let declaredKind, declaredKind != attachment.kind {
                return nil
            }
            return attachment
        }.value
    }

    /// Whether an attachment path may be read: a file of the session's
    /// workspace, or of a system temporary directory. A `session/prompt` is the
    /// client's, and everything it reads is forwarded to the provider, so the
    /// request does not turn the agent into a reader of the whole disk.
    static func isReadableAttachmentLocation(_ url: URL, cwd: String) -> Bool {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [
            URL(fileURLWithPath: cwd, isDirectory: true),
            FileManager.default.temporaryDirectory,
        ]
        return roots.contains { root in
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            return path == rootPath || path.hasPrefix(prefix)
        }
    }

    /// The media kind an attachment declares: the `mimeType` decides when the
    /// request sends one (and a `mimeType` that is not media means the block is
    /// no attachment at all), else the name's extension. A block with neither
    /// stays an image, as it always was.
    private static func attachmentKind(
        mimeType: String?,
        filename: String?
    ) -> AgentRuntimeAttachment.Kind? {
        if let mimeType = mimeType?.lowercased().nilIfBlank {
            if mimeType.hasPrefix("image/") {
                return .image
            }
            if mimeType.hasPrefix("video/") {
                return .video
            }
            return nil
        }
        guard let filename = filename?.nilIfBlank else {
            return .image
        }
        guard !(filename as NSString).pathExtension.isEmpty else {
            return .image
        }
        return (try? AgentRuntimeAttachmentStore.attachmentKind(for: URL(fileURLWithPath: filename)))
    }

    private static func firstBase64Data(in object: [String: Any]) -> Data? {
        for key in ["data", "blob", "base64", "bytes"] {
            guard let value = stringValue(object[key])?.nilIfBlank else {
                continue
            }
            if let (_, data) = imageDataURL(value) {
                return data
            }
            if let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
                return data
            }
        }
        return nil
    }

    private static func imageDataURL(_ value: String) -> (mimeType: String?, data: Data)? {
        guard value.lowercased().hasPrefix("data:"),
              let separatorRange = value.range(of: ";base64,") else {
            return nil
        }
        let mimeType = String(value[value.index(value.startIndex, offsetBy: 5)..<separatorRange.lowerBound])
            .nilIfBlank
        let base64 = String(value[separatorRange.upperBound...])
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) else {
            return nil
        }
        return (mimeType, data)
    }

    private static func fileURL(from value: String, cwd: String) -> URL? {
        if let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value).standardizedFileURL
        }
        guard !value.contains("://") else {
            return nil
        }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(value)
            .standardizedFileURL
    }

    private static func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key])?.nilIfBlank {
                return value
            }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        return nil
    }

    private static func embeddedAttachmentFilename(contentType: String?) -> String {
        let fileExtension = AgentRuntimeAttachmentStore.preferredFilenameExtension(
            originalFilename: "",
            contentType: contentType
        )
        return fileExtension.isEmpty ? "attachment" : "attachment.\(fileExtension)"
    }
}
