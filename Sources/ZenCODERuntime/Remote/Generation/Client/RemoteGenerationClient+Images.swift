//
//  RemoteGenerationClient+Images.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension RemoteGenerationClient {
    /// Returns a copy of `messages` with all `image_url` content blocks removed.
    /// Content that was an array of blocks is collapsed back to a plain text
    /// string when only text remains, or set to an empty string when the array
    /// contained only image blocks.
    public static func messagesStrippingImageContent(from messages: [[String: Any]]) -> [[String: Any]] {
        messages.map { message in
            var stripped = message
            guard var items = message["content"] as? [[String: Any]] else {
                return stripped
            }
            items.removeAll { item in
                stringValue(item["type"])?.lowercased() == "image_url"
            }
            if items.isEmpty {
                stripped["content"] = ""
            } else if items.count == 1,
                      stringValue(items[0]["type"])?.lowercased() == "text" {
                stripped["content"] = stringValue(items[0]["text"]) ?? ""
            } else {
                stripped["content"] = items
            }
            return stripped
        }
    }

    /// Returns `true` when any message in the array contains at least one
    /// `image_url` content block.
    public static func messagesContainImageContent(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            !chatCompletionsImageContentItems(from: message["content"]).isEmpty
        }
    }

    /// Returns `true` when the error indicates the remote provider rejected
    /// `image_url` content blocks because it only accepts `text` blocks.
    /// This is common with OpenAI-compatible proxies and non-vision models
    /// that use strict serde deserialization on the server side.
    public static func isImageContentRejectedError(_ error: Error) -> Bool {
        let lowercased: String
        if case let .remoteFailure(message)? = error as? RemoteGenerationClientError {
            lowercased = message.lowercased()
        } else {
            lowercased = String(describing: error).lowercased()
        }
        return lowercased.contains("image_url")
            && (lowercased.contains("expected `text`")
                || lowercased.contains("expected text")
                || lowercased.contains("unknown variant"))
    }

    public static func chatCompletionsImageContentItems(from value: Any?) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.filter { item in
            stringValue(item["type"])?.lowercased() == "image_url"
                && chatCompletionsImageURL(from: item)?.nilIfBlank != nil
        }
    }

    public static func chatCompletionsImageURL(from item: [String: Any]) -> String? {
        if let imageURL = item["image_url"] as? String {
            return imageURL
        }
        return stringValue((item["image_url"] as? [String: Any])?["url"])
    }

    public static func runtimeImageAttachment(
        from item: [String: Any],
        index: Int
    ) -> AgentRuntimeAttachment? {
        guard let dataURL = chatCompletionsImageURL(from: item)?.nilIfBlank,
              dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let metadataStart = dataURL.index(dataURL.startIndex, offsetBy: "data:".count)
        let metadata = String(dataURL[metadataStart..<commaIndex])
        let components = metadata.split(separator: ";", omittingEmptySubsequences: true)
        let contentType = components.first.map(String.init)?.nilIfBlank ?? "image/png"
        let encodedPayload = String(dataURL[dataURL.index(after: commaIndex)...])
        let data: Data?
        if components.dropFirst().contains(where: { $0.lowercased() == "base64" }) {
            data = Data(base64Encoded: encodedPayload)
        } else {
            data = encodedPayload.removingPercentEncoding.map { Data($0.utf8) }
        }
        guard let data else { return nil }

        let pathExtension = AgentRuntimeAttachmentStore.preferredFilenameExtension(
            originalFilename: "",
            contentType: contentType
        )
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return AgentRuntimeAttachment(
            kind: .image,
            data: data,
            contentType: contentType,
            originalFilename: "image-\(index + 1)\(suffix)"
        )
    }

    public static func imageDataURLs(from attachments: [AgentRuntimeAttachment]) -> [String] {
        attachments.compactMap { attachment in
            guard attachment.kind == .image,
                  let data = attachmentData(for: attachment) else {
                return nil
            }
            return "data:\(mimeType(for: attachment));base64,\(data.base64EncodedString())"
        }
    }

    public static func attachmentData(for attachment: AgentRuntimeAttachment) -> Data? {
        if let data = attachment.data {
            return data
        }
        guard let fileURL = attachment.fileURL else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    public static func mimeType(for attachment: AgentRuntimeAttachment) -> String {
        if let contentType = attachment.contentType,
           contentType.contains("/") {
            return contentType
        }

        let pathExtension = URL(fileURLWithPath: attachment.originalFilename)
            .pathExtension
            .lowercased()
        switch pathExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "heic": return "image/heic"
        default: return "image/png"
        }
    }

    static func responsesToolImageItems(from message: [String: Any]) -> [[String: Any]] {
        let images = responsesContentItems(from: message["content"], role: "user")
            .filter { stringValue($0["type"])?.lowercased() == "input_image" }
        guard !images.isEmpty else {
            return []
        }
        return [[
            "type": "input_text",
            "text": toolGeneratedMediaLabel(from: message)
        ]] + images
    }

    static func toolGeneratedMediaLabel(from message: [String: Any]) -> String {
        let toolName = stringValue(message["name"])?.nilIfBlank ?? "tool"
        let callSuffix = stringValue(message["tool_call_id"])?.nilIfBlank.map { " for call '\($0)'" } ?? ""
        return "Image returned by tool '\(toolName)'\(callSuffix)."
    }

    public static func isResponseToolCallItem(_ item: [String: Any]) -> Bool {
        let type = stringValue(item["type"])?.lowercased()
        return type == "function_call" || type == "custom_tool_call"
    }

    public static func isResponseReasoningItem(_ item: [String: Any]) -> Bool {
        stringValue(item["type"])?.lowercased() == "reasoning"
    }

    public static func responseOutputText(from item: [String: Any]) -> String? {
        guard stringValue(item["type"])?.lowercased() == "message" else {
            return nil
        }
        if let string = item["content"] as? String {
            return string
        }
        guard let items = item["content"] as? [[String: Any]] else { return nil }
        let text = items.compactMap { ($0["text"] as? String) ?? ($0["content"] as? String) }.joined()
        return text.isEmpty ? nil : text
    }
}
