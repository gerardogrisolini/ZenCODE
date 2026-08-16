import Foundation
import ToolCore

/// Authentication-free Anthropic Messages wire conversion. This type only
/// translates JSON-shaped conversation values and can be reused by Direct and
/// Subscription clients without sharing either client's request policy.
enum AnthropicMessagesWireCodec {
    static func payload(from messages: [[String: Any]]) -> (system: String?, messages: [[String: Any]]) {
        var system: [String] = []
        var output: [[String: Any]] = []
        for message in messages {
            let role = RemoteGenerationClient.stringValue(message["role"])?.lowercased() ?? ""
            if role == "system" {
                if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
                    system.append(text)
                }
                continue
            }
            switch role {
            case "assistant":
                let blocks = assistantBlocks(from: message)
                if !blocks.isEmpty { output.append(["role": "assistant", "content": blocks]) }
            case "tool":
                guard let block = toolResultBlock(from: message) else { continue }
                appendUser(blocks: [block], to: &output)
            default:
                let blocks = userBlocks(from: message["content"])
                if !blocks.isEmpty { appendUser(blocks: blocks, to: &output) }
            }
        }
        return (system.joined(separator: "\n\n").nilIfBlank, output)
    }

    static func assistantBlocks(from message: [String: Any]) -> [[String: Any]] {
        if let exact = decodedBlocks(message["anthropic_content_blocks"]), !exact.isEmpty {
            return exact
        }
        var blocks = decodedBlocks(message["thinking_blocks"]) ?? []
        if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
            blocks.append(["type": "text", "text": text])
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            blocks.append(contentsOf: calls.compactMap(toolUseBlock))
        }
        return blocks
    }

    static func decodedBlocks(_ value: Any?) -> [[String: Any]]? {
        if let blocks = value as? [[String: Any]] { return blocks.compactMap(validAssistantBlock) }
        guard let string = RemoteGenerationClient.stringValue(value),
              let data = string.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .array(values) = json else { return nil }
        return values.compactMap { $0.jsonObject as? [String: Any] }.compactMap(validAssistantBlock)
    }

    /// Keeps every replay-relevant field and the original block order. Empty
    /// thinking text is valid when Anthropic supplied a signature.
    static func validAssistantBlock(_ block: [String: Any]) -> [String: Any]? {
        switch RemoteGenerationClient.stringValue(block["type"])?.lowercased() {
        case "thinking":
            guard let signature = RemoteGenerationClient.stringValue(block["signature"])?.nilIfBlank,
                  let thinking = RemoteGenerationClient.stringValue(block["thinking"]) else { return nil }
            var preserved = block
            preserved["thinking"] = thinking
            preserved["signature"] = signature
            return preserved
        case "redacted_thinking":
            guard let data = RemoteGenerationClient.stringValue(block["data"])?.nilIfBlank else { return nil }
            var preserved = block
            preserved["data"] = data
            return preserved
        case "text":
            guard let text = RemoteGenerationClient.stringValue(block["text"]) else { return nil }
            var preserved = block
            preserved["text"] = text
            return preserved
        case "tool_use":
            guard let id = RemoteGenerationClient.stringValue(block["id"])?.nilIfBlank,
                  let name = RemoteGenerationClient.stringValue(block["name"])?.nilIfBlank else { return nil }
            var preserved = block
            preserved["id"] = id
            preserved["name"] = name
            if preserved["input"] == nil { preserved["input"] = [:] }
            return preserved
        default: return nil
        }
    }

    static func userBlocks(from value: Any?) -> [[String: Any]] {
        if let string = value as? String { return string.nilIfBlank.map { [["type": "text", "text": $0]] } ?? [] }
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            switch RemoteGenerationClient.stringValue(item["type"])?.lowercased() {
            case "text", "input_text", "output_text":
                guard let text = RemoteGenerationClient.stringValue(item["text"])?.nilIfBlank else { return nil }
                return ["type": "text", "text": text]
            case "image_url", "input_image":
                guard let url = RemoteGenerationClient.chatCompletionsImageURL(from: item) else { return nil }
                return imageBlock(dataURL: url)
            default: return nil
            }
        }
    }

    static func toolUseBlock(_ call: [String: Any]) -> [String: Any]? {
        guard let function = call["function"] as? [String: Any],
              let name = RemoteGenerationClient.stringValue(function["name"])?.nilIfBlank else { return nil }
        let id = RemoteGenerationClient.stringValue(call["id"])?.nilIfBlank ?? "toolu_\(UUID().uuidString.lowercased())"
        let input: Any
        if let arguments = RemoteGenerationClient.stringValue(function["arguments"]),
           let data = arguments.data(using: .utf8),
           let json = try? JSONDecoder().decode(JSONValue.self, from: data) { input = json.jsonObject }
        else { input = [:] }
        return ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    static func toolResultBlock(from message: [String: Any]) -> [String: Any]? {
        guard let id = RemoteGenerationClient.stringValue(message["tool_call_id"])?.nilIfBlank else { return nil }
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": id]
        let images = RemoteGenerationClient.chatCompletionsImageContentItems(from: message["content"])
        if images.isEmpty { block["content"] = RemoteGenerationClient.contentString(from: message["content"]) ?? "" }
        else { block["content"] = userBlocks(from: message["content"]) }
        if (message["is_error"] as? Bool) == true { block["is_error"] = true }
        return block
    }

    static func imageBlock(dataURL: String) -> [String: Any]? {
        guard dataURL.hasPrefix("data:"), let comma = dataURL.firstIndex(of: ",") else { return nil }
        let metadata = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<comma])
        let parts = metadata.split(separator: ";").map(String.init)
        guard parts.contains("base64"), let media = parts.first,
              ["image/jpeg", "image/png", "image/gif", "image/webp"].contains(media) else { return nil }
        let data = String(dataURL[dataURL.index(after: comma)...])
        guard !data.isEmpty else { return nil }
        return ["type": "image", "source": ["type": "base64", "media_type": media, "data": data]]
    }

    private static func appendUser(blocks: [[String: Any]], to output: inout [[String: Any]]) {
        if let last = output.indices.last, output[last]["role"] as? String == "user",
           var content = output[last]["content"] as? [[String: Any]] {
            content.append(contentsOf: blocks); output[last]["content"] = content
        } else { output.append(["role": "user", "content": blocks]) }
    }

    static func jsonString(_ blocks: [[String: Any]]) -> String? {
        guard let data = try? JSONValue(jsonObject: blocks).jsonData(outputFormatting: [.withoutEscapingSlashes]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
