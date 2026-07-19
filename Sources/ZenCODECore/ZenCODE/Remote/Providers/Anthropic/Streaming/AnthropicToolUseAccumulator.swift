//
//  AnthropicToolUseAccumulator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct AnthropicToolUseAccumulator {
    struct PartialToolUse {
        var id: String
        var name: String
        var inputObject: [String: Any]?
        var partialJSON = ""
    }

    private var partialsByIndex: [Int: PartialToolUse] = [:]

    mutating func ingestContentBlockStart(_ object: [String: Any]) {
        guard let index = AnthropicSubscriptionGenerationClient.intValue(object["index"]),
              let contentBlock = object["content_block"] as? [String: Any],
              AnthropicSubscriptionGenerationClient.stringValue(contentBlock["type"])?.lowercased() == "tool_use",
              let id = AnthropicSubscriptionGenerationClient.stringValue(contentBlock["id"])?.nilIfBlank,
              let name = AnthropicSubscriptionGenerationClient.stringValue(contentBlock["name"])?.nilIfBlank else {
            return
        }
        partialsByIndex[index] = PartialToolUse(
            id: id,
            name: name,
            inputObject: contentBlock["input"] as? [String: Any]
        )
    }

    mutating func ingestInputJSONDelta(index: Int, partialJSON: String) {
        guard !partialJSON.isEmpty else {
            return
        }
        var partial = partialsByIndex[index] ?? PartialToolUse(
            id: "toolu_\(UUID().uuidString.lowercased())",
            name: "tool",
            inputObject: nil
        )
        partial.partialJSON.append(partialJSON)
        partialsByIndex[index] = partial
    }

    func finalize() -> [DirectAgentToolCall] {
        partialsByIndex.keys.sorted().compactMap { index in
            guard let partial = partialsByIndex[index] else {
                return nil
            }
            let argumentsJSON: String
            let argumentsObject: [String: Any]
            if let object = partial.inputObject, partial.partialJSON.isEmpty {
                argumentsObject = object
                argumentsJSON = AgentJSONSupport.jsonString(from: object)
            } else {
                argumentsJSON = partial.partialJSON.nilIfBlank ?? "{}"
                argumentsObject = AnthropicSubscriptionGenerationClient.jsonObject(fromJSONString: argumentsJSON)
            }
            return DirectAgentToolCall(
                id: partial.id,
                name: partial.name,
                argumentsObject: argumentsObject,
                argumentsJSON: argumentsJSON
            )
        }
    }
}
