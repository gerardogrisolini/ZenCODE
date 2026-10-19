//
//  ZenCODEACPBridge+Attachments.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension ZenCODEACPBridge {
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

    public static func promptAttachments(
        from blocks: [Any],
        renderedPromptText _: String,
        cwd: String
    ) -> [AgentRuntimeAttachment] {
        var attachments: [AgentRuntimeAttachment] = []
        var seenKeys = Set<String>()

        func append(_ attachment: AgentRuntimeAttachment?) {
            guard let attachment else {
                return
            }
            let key = attachment.fileURL?.standardizedFileURL.path
                ?? "\(attachment.originalFilename):\(attachment.data?.count ?? 0)"
            guard seenKeys.insert(key).inserted else {
                return
            }
            attachments.append(attachment)
        }

        for block in blocks {
            append(promptAttachment(from: block, cwd: cwd))
        }
        return attachments
    }

    private static func promptAttachment(from block: Any, cwd: String) -> AgentRuntimeAttachment? {
        guard let object = block as? [String: Any] else {
            return nil
        }
        let type = stringValue(object["type"])?.lowercased() ?? "text"

        switch type {
        case "image", "input_image":
            return imageAttachment(from: object, cwd: cwd)
        case "image_url":
            return imageURLAttachment(from: object["image_url"], cwd: cwd)
        case "resource":
            guard let resource = object["resource"] as? [String: Any] else {
                return nil
            }
            return imageAttachment(from: resource, cwd: cwd)
        default:
            if let imageURL = object["image_url"] {
                return imageURLAttachment(from: imageURL, cwd: cwd)
            }
            return nil
        }
    }

    private static func imageAttachment(from object: [String: Any], cwd: String) -> AgentRuntimeAttachment? {
        let contentType = firstString(
            in: object,
            keys: ["mimeType", "mime_type", "mediaType", "media_type", "contentType", "content_type"]
        )
        let originalFilename = firstString(in: object, keys: ["filename", "fileName", "name", "title"])
        if let data = firstBase64Data(in: object) {
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType,
                originalFilename: originalFilename
                    ?? embeddedAttachmentFilename(contentType: contentType)
            )
        }

        if let uri = firstString(in: object, keys: ["uri", "url", "path", "image_url"]),
           let attachment = imageURLAttachment(from: uri, cwd: cwd, contentType: contentType) {
            return attachment
        }
        return nil
    }

    private static func imageURLAttachment(
        from value: Any?,
        cwd: String,
        contentType: String? = nil
    ) -> AgentRuntimeAttachment? {
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
            return AgentRuntimeAttachment(
                kind: .image,
                data: data,
                contentType: contentType ?? mimeType,
                originalFilename: embeddedAttachmentFilename(contentType: contentType ?? mimeType)
            )
        }
        guard let fileURL = fileURL(from: rawURL, cwd: cwd) else {
            return nil
        }
        return try? AgentRuntimeAttachmentStore.importFile(from: fileURL).runtimeAttachment
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
        return fileExtension.isEmpty ? "image" : "image.\(fileExtension)"
    }
}
