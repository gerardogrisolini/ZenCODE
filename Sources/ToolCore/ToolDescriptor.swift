//
//  ToolDescriptor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated struct ToolDescriptor: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?

    public enum CodingKeys: String, CodingKey {
        case name, title, description, inputSchema, outputSchema
    }

    public init(
        name: String,
        title: String? = nil,
        description: String,
        inputSchema: String,
        outputSchema: String? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }

    public func promptDescription() -> String {
        let titleLine = title.map { "\n  title: \($0)" } ?? ""
        let requiredLine = requiredInputArgumentNames().isEmpty
            ? ""
            : "\n  required_arguments: \(requiredInputArgumentNames().joined(separator: ", "))"
        return """
        - name: \(name)\(titleLine)\(requiredLine)
          description: \(description)
                    input_schema: \(inputSchema.replacingOccurrences(of: "\n", with: "\n    "))
        """
    }

    public func compactPromptDescription() -> String {
        let requiredArguments = requiredInputArgumentNames()
        guard !requiredArguments.isEmpty else {
            return "- \(name): \(description)"
        }

        return "- \(name)(requires: \(requiredArguments.joined(separator: ", "))): \(description)"
    }

    public func toolCallDescription() -> String {
        let requiredArguments = requiredInputArgumentNames()
        guard !requiredArguments.isEmpty else {
            return description
        }

        return """
        \(description)
        Required arguments: \(requiredArguments.joined(separator: ", ")).
        Do not call this tool with empty arguments; provide non-empty values for every required argument.
        """
    }

    public func requiredInputArgumentNames() -> [String] {
        guard let schema = inputSchemaJSONValue(),
              case let .object(object) = schema,
              case let .array(requiredValues)? = object["required"] else {
            return []
        }

        return requiredValues.compactMap(\.stringValue)
    }

    private func inputSchemaJSONValue() -> JSONValue? {
        guard let data = inputSchema.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func prefixed(with prefix: String) -> ToolDescriptor {
        ToolDescriptor(
            name: "\(prefix)\(name)",
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
    }

    public static func fromJSON(_ jsonString: String) -> ToolDescriptor? {
        guard let data = jsonString.data(using:.utf8) else {
            return ToolDescriptor(name: jsonString, description: "", inputSchema: "{}")
        }

        do {
            if let dict = try JSONDecoder().decode(JSONValue.self, from: data).objectValue {
                let name = dict["name"]?.stringValue ?? jsonString
                let title = dict["title"]?.stringValue
                let description = dict["description"]?.stringValue ?? ""
                
                let inputSchema = dict["input_schema"]?.stringValue ?? dict["inputSchema"]?.stringValue ?? "{}"
                let outputSchema = dict["output_schema"]?.stringValue ?? dict["outputSchema"]?.stringValue

                return ToolDescriptor(
                    name: name,
                    title: title,
                    description: description,
                    inputSchema: inputSchema,
                    outputSchema: outputSchema
                )
            }
        } catch {
            return ToolDescriptor(name: jsonString, description: "", inputSchema: "{}")
        }

        return ToolDescriptor(name: jsonString, description: "", inputSchema: "{}")
    }

    public static func canonicalized(_ tools: [ToolDescriptor]) -> [ToolDescriptor] {
        tools.sorted(by: canonicalSortOrder(lhs: rhs:))
    }

    private static func canonicalSortOrder(lhs: ToolDescriptor, rhs: ToolDescriptor) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }

        if lhs.title != rhs.title {
            return (lhs.title ?? "") < (rhs.title ?? "")
        }

        if lhs.description != rhs.description {
            return lhs.description < rhs.description
        }

        if lhs.inputSchema != rhs.inputSchema {
            return lhs.inputSchema < rhs.inputSchema
        }

        return (lhs.outputSchema ?? "") < (rhs.outputSchema ?? "")
    }
}

public nonisolated struct ToolProviderSection: Hashable, Sendable {
    public let name: String
    public let toolHeading: String
    public let followUpLabel: String
    public let tools: [ToolDescriptor]

    public init(
        name: String,
        toolHeading: String,
        followUpLabel: String,
        tools: [ToolDescriptor]
    ) {
        self.name = name
        self.toolHeading = toolHeading
        self.followUpLabel = followUpLabel
        self.tools = tools
    }

    public func canonicalized() -> ToolProviderSection {
        ToolProviderSection(
            name: name,
            toolHeading: toolHeading,
            followUpLabel: followUpLabel,
            tools: ToolDescriptor.canonicalized(tools)
        )
    }

    public static func canonicalized(_ providers: [ToolProviderSection]) -> [ToolProviderSection] {
        providers
            .map { $0.canonicalized() }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name {
                    return lhs.name < rhs.name
                }

                if lhs.toolHeading != rhs.toolHeading {
                    return lhs.toolHeading < rhs.toolHeading
                }

                return lhs.followUpLabel < rhs.followUpLabel
            }
    }
}
