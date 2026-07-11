//
//  RemoteToolCallAccumulator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct RemoteToolCallAccumulator {
    public struct PartialToolCall {
        public var id = ""
        public var responseItemID = ""
        public var name = ""
        public var arguments = ""
    }

    public var partialsByIndex: [Int: PartialToolCall] = [:]
    public var indexesByResponseItemID: [String: Int] = [:]
    public var indexesByCallID: [String: Int] = [:]

    public mutating func ingestChatCompletionToolCalls(_ rawToolCalls: [[String: Any]]) {
        for (offset, rawToolCall) in rawToolCalls.enumerated() {
            let index = integerValue(rawToolCall["index"]) ?? offset
            var partial = partialsByIndex[index] ?? PartialToolCall()

            if let id = stringValue(rawToolCall["id"]), !id.isEmpty {
                partial.id = id
            }
            if let function = rawToolCall["function"] as? [String: Any] {
                if let name = stringValue(function["name"]), !name.isEmpty {
                    partial.name = name
                }
                if let arguments = stringValue(function["arguments"]) {
                    partial.arguments.append(arguments)
                }
            }
            partialsByIndex[index] = partial
        }
    }

    public mutating func ingestResponseToolCallItem(
        _ item: [String: Any],
        outputIndex: Int?
    ) {
        let index = responseIndex(from: item, outputIndex: outputIndex)
        var partial = partialsByIndex[index] ?? PartialToolCall()

        if let itemID = stringValue(item["id"]), !itemID.isEmpty {
            partial.responseItemID = itemID
            indexesByResponseItemID[itemID] = index
        }
        if let callID = stringValue(item["call_id"]), !callID.isEmpty {
            partial.id = callID
            indexesByCallID[callID] = index
        } else if partial.id.isEmpty,
                  let id = stringValue(item["id"]),
                  !id.isEmpty {
            partial.id = id
        }
        if let name = stringValue(item["name"]), !name.isEmpty {
            partial.name = name
        }
        if let arguments = responseArguments(from: item), !arguments.isEmpty {
            partial.arguments = arguments
        }

        partialsByIndex[index] = partial
    }

    public mutating func ingestResponseToolCallArgumentsDelta(_ event: [String: Any]) {
        let index = responseIndex(from: event)
        var partial = partialsByIndex[index] ?? PartialToolCall()
        if let itemID = stringValue(event["item_id"]), !itemID.isEmpty {
            partial.responseItemID = itemID
            indexesByResponseItemID[itemID] = index
        }
        if let callID = stringValue(event["call_id"]), !callID.isEmpty {
            partial.id = callID
            indexesByCallID[callID] = index
        }
        if let delta = stringValue(event["delta"]), !delta.isEmpty {
            partial.arguments.append(delta)
        }
        partialsByIndex[index] = partial
    }

    public mutating func ingestResponseToolCallArgumentsDone(_ event: [String: Any]) {
        let index = responseIndex(from: event)
        var partial = partialsByIndex[index] ?? PartialToolCall()
        if let itemID = stringValue(event["item_id"]), !itemID.isEmpty {
            partial.responseItemID = itemID
            indexesByResponseItemID[itemID] = index
        }
        if let callID = stringValue(event["call_id"]), !callID.isEmpty {
            partial.id = callID
            indexesByCallID[callID] = index
        }
        if let name = stringValue(event["name"]), !name.isEmpty {
            partial.name = name
        }
        if let arguments = stringValue(event["arguments"]), !arguments.isEmpty {
            partial.arguments = arguments
        }
        if let item = event["item"] as? [String: Any] {
            if let callID = stringValue(item["call_id"]), !callID.isEmpty {
                partial.id = callID
                indexesByCallID[callID] = index
            }
            if let name = stringValue(item["name"]), !name.isEmpty {
                partial.name = name
            }
            if let arguments = responseArguments(from: item), !arguments.isEmpty {
                partial.arguments = arguments
            }
        }
        partialsByIndex[index] = partial
    }

    public func finalize() throws -> [DirectAgentToolCall] {
        try coalescedPartials().map { partial in
            let argumentsObject = try Self.argumentsObject(from: partial.arguments)
            return DirectAgentToolCall(
                id: partial.id.isEmpty ? "call_\(UUID().uuidString.lowercased())" : partial.id,
                name: partial.name,
                argumentsObject: argumentsObject,
                argumentsJSON: Self.normalizedArgumentsJSON(from: argumentsObject)
            )
        }
    }

    /// Collapses partials that describe the same logical tool call before emitting.
    ///
    /// A streamed `output_item.added` event can carry a tool call's `call_id`
    /// while the argument-delta/`done` events key off the response `item_id`.
    /// When those identifiers resolve to different indices the single call is
    /// split into an empty-argument partial plus a fully populated one. Emitting
    /// both duplicates the tool in the UI ("first call empty") and replays two
    /// `function_call` items sharing the same `call_id` back to the provider,
    /// which rejects the request with a generic server error. Merging by shared
    /// `id`/`responseItemID` keeps a single, complete call.
    func coalescedPartials() -> [PartialToolCall] {
        var merged: [PartialToolCall] = []
        var indexByCallID: [String: Int] = [:]
        var indexByItemID: [String: Int] = [:]

        for index in partialsByIndex.keys.sorted() {
            guard let partial = partialsByIndex[index] else {
                continue
            }
            let callID = partial.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let itemID = partial.responseItemID.trimmingCharacters(in: .whitespacesAndNewlines)

            let targetIndex: Int?
            if !callID.isEmpty, let existing = indexByCallID[callID] {
                targetIndex = existing
            } else if !itemID.isEmpty, let existing = indexByItemID[itemID] {
                targetIndex = existing
            } else {
                targetIndex = nil
            }

            if let targetIndex {
                merged[targetIndex] = Self.mergedPartial(merged[targetIndex], partial)
            } else {
                merged.append(partial)
            }

            let resolvedIndex = targetIndex ?? (merged.count - 1)
            let resolvedCallID = merged[resolvedIndex].id
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedItemID = merged[resolvedIndex].responseItemID
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolvedCallID.isEmpty {
                indexByCallID[resolvedCallID] = resolvedIndex
            }
            if !resolvedItemID.isEmpty {
                indexByItemID[resolvedItemID] = resolvedIndex
            }
        }

        return merged.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Merges `addition` into `base`, preferring non-empty identifiers/names and
    /// the most meaningful arguments (a real JSON object over an empty `{}`).
    static func mergedPartial(
        _ base: PartialToolCall,
        _ addition: PartialToolCall
    ) -> PartialToolCall {
        var result = base
        if result.id.isEmpty {
            result.id = addition.id
        }
        if result.responseItemID.isEmpty {
            result.responseItemID = addition.responseItemID
        }
        if result.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.name = addition.name
        }

        let baseArguments = result.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let additionArguments = addition.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseIsMeaningful = !baseArguments.isEmpty && baseArguments != "{}"
        let additionIsMeaningful = !additionArguments.isEmpty && additionArguments != "{}"
        if additionIsMeaningful, !baseIsMeaningful {
            result.arguments = addition.arguments
        } else if baseArguments.isEmpty, !additionArguments.isEmpty {
            result.arguments = addition.arguments
        }
        return result
    }

    public static func argumentsObject(from rawArguments: String) throws -> [String: Any] {
        let trimmed = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [:]
        }
        guard let data = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            throw RemoteGenerationClientError.invalidToolArguments
        }
        return object.mapValues(\.jsonObject)
    }

    public static func normalizedArgumentsJSON(from object: [String: Any]) -> String {
        JSONValue(jsonObject: object).compactString(sortedKeys: true)
    }

    public func integerValue(_ value: Any?) -> Int? {
        JSONValue(jsonObject: value).intValue
    }

    public mutating func responseIndex(
        from object: [String: Any],
        outputIndex: Int? = nil
    ) -> Int {
        if let itemID = stringValue(object["item_id"] ?? object["id"]),
           let index = indexesByResponseItemID[itemID] {
            return index
        }
        if let callID = stringValue(object["call_id"]),
           let index = indexesByCallID[callID] {
            return index
        }
        if let outputIndex {
            return outputIndex
        }
        if let index = integerValue(object["output_index"]) {
            return index
        }

        let highestKnownIndex = max(
            partialsByIndex.keys.max() ?? -1,
            indexesByResponseItemID.values.max() ?? -1,
            indexesByCallID.values.max() ?? -1
        )
        let index = highestKnownIndex + 1
        if let itemID = stringValue(object["item_id"] ?? object["id"]), !itemID.isEmpty {
            indexesByResponseItemID[itemID] = index
        }
        if let callID = stringValue(object["call_id"]), !callID.isEmpty {
            indexesByCallID[callID] = index
        }
        return index
    }

    public func responseArguments(from item: [String: Any]) -> String? {
        if let arguments = stringValue(item["arguments"]) {
            return arguments
        }
        if let arguments = stringValue(item["input"]) {
            return arguments
        }
        if let arguments = item["arguments"],
           let json = normalizedJSONValue(from: arguments) {
            return json
        }
        if let input = item["input"],
           let json = normalizedJSONValue(from: input) {
            return json
        }
        return nil
    }

    public func stringValue(_ value: Any?) -> String? {
        JSONValue(jsonObject: value).flexibleStringValue
    }

    public func normalizedJSONValue(from value: Any) -> String? {
        JSONValue(jsonObject: value).compactString(sortedKeys: true)
    }
}
