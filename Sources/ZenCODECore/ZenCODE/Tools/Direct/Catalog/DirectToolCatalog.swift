//
//  DirectToolCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import LocalToolsSupport

public struct DirectToolDescriptor: Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?
    public let presentation: ToolPresentationDefinition?

    public init(
        name: String,
        description: String,
        inputSchema: String,
        title: String? = nil,
        outputSchema: String? = nil,
        presentation: ToolPresentationDefinition? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
        self.presentation = presentation
    }
}

public enum DirectToolCatalog {
    public static var baseDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        coreLocalFileAndTextDescriptors + coreProcessDescriptors + skillToolDescriptors + featureDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#else
        coreLocalFileAndTextDescriptors + skillToolDescriptors + featureDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#endif
    }

    /// Intrinsic, always-on prompt-skill tools (`skills.list`, `skills.read`).
    /// They are not user-selectable from `/tools` and remain available even when
    /// every user tool group is disabled.
    public static var skillToolDescriptors: [DirectToolDescriptor] {
        PromptSkillToolProvider.descriptors
    }

    public static var selectableDescriptors: [DirectToolDescriptor] {
        baseDescriptors
    }

    public static var coreLocalFileAndTextDescriptors: [DirectToolDescriptor] {
        filesystemDescriptors.filter {
            $0.name.hasPrefix("local.") || $0.name.hasPrefix("text.")
        }
    }

    public static var localSearchDescriptors: [DirectToolDescriptor] {
        filesystemDescriptors.filter { $0.name.hasPrefix("search.") }
    }

    public static let filesystemDescriptors: [DirectToolDescriptor] = (
        LocalFeatureTools.fileTools()
            + LocalFeatureTools.searchTools()
            + LocalFeatureTools.textTools()
    ).map(\.descriptor.toolDescriptor).map(DirectToolDescriptor.init)

    public static let memoryDescriptors: [DirectToolDescriptor] =
        MemoryTool.toolDescriptors.map(DirectToolDescriptor.init)

    public static var featureDescriptors: [DirectToolDescriptor] {
        SwiftFeatureRuntime.managementToolDescriptors
    }

#if canImport(Darwin) || canImport(Glibc)
    public static var coreProcessDescriptors: [DirectToolDescriptor] {
        DirectProcessTools.descriptors
    }
#endif

    public static var todoTaskDescriptors: [DirectToolDescriptor] {
        DirectTodoRuntime.toolDescriptors
    }

    public static var subAgentDescriptors: [DirectToolDescriptor] {
        DirectSubAgentRuntime.toolDescriptors
    }
}

extension DirectToolDescriptor {
    public init(toolDescriptor: ToolDescriptor) {
        self.init(
            name: toolDescriptor.name,
            description: toolDescriptor.description,
            inputSchema: toolDescriptor.inputSchema,
            title: toolDescriptor.title,
            outputSchema: toolDescriptor.outputSchema,
            presentation: toolDescriptor.presentation
        )
    }

    public var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema,
            presentation: presentation
        )
    }

    public var schemaObject: Any? {
        guard let data = inputSchema.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(JSONValue.self, from: data).jsonObject
    }
}

public struct AgentToolProviderRegistry: Sendable {
    public var providers: [AgentToolProvider] = []

    public mutating func update(_ providers: [AgentToolProvider]) {
        self.providers = providers
    }

    public var descriptors: [DirectToolDescriptor] {
        var seenNames = Set<String>()
        var selected: [ToolDescriptor] = []
        for provider in providers {
            for tool in ToolDescriptor.canonicalized(provider.tools)
            where seenNames.insert(tool.name).inserted {
                selected.append(tool)
            }
        }
        return ToolDescriptor.canonicalized(selected).map(DirectToolDescriptor.init)
    }

    public func executor(for toolName: String) -> AgentToolExecutor? {
        for provider in providers where provider.tools.contains(where: { $0.name == toolName }) {
            return provider.executor
        }
        return nil
    }
}
