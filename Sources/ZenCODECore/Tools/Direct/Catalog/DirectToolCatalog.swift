//
//  DirectToolCatalog.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import FeatureKit
import Foundation
import LocalToolsSupport
import Synchronization
import ToolCore

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

    /// All built-in descriptors whose mutability is owned by this catalog.
    ///
    /// Optional feature, MCP, and externally provided descriptors deliberately
    /// do not appear here: their authorization remains unchanged by an agent
    /// profile's `readOnly` setting.
    public static var coreDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        coreLocalFileAndTextDescriptors + coreProcessDescriptors + skillToolDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#else
        coreLocalFileAndTextDescriptors + skillToolDescriptors + memoryDescriptors + todoTaskDescriptors + subAgentDescriptors
#endif
    }

    /// The non-mutating subset of `coreDescriptors`.
    public static var coreReadDescriptors: [DirectToolDescriptor] {
        coreReadLocalFileAndTextDescriptors
            + skillToolDescriptors
            + coreReadMemoryDescriptors
            + coreReadTodoTaskDescriptors
            + coreReadSubAgentDescriptors
    }

    /// The mutating subset of `coreDescriptors`.
    public static var coreMutatingDescriptors: [DirectToolDescriptor] {
#if canImport(Darwin) || canImport(Glibc)
        coreMutatingLocalFileAndTextDescriptors
            + coreProcessDescriptors
            + coreMutatingMemoryDescriptors
            + coreMutatingTodoTaskDescriptors
            + coreMutatingSubAgentDescriptors
#else
        coreMutatingLocalFileAndTextDescriptors
            + coreMutatingMemoryDescriptors
            + coreMutatingTodoTaskDescriptors
            + coreMutatingSubAgentDescriptors
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

    /// The core local tools executed in-process: Files (`local.*` except
    /// `local.exec`), Search (`search.*`), and Text (`text.*`). Built once:
    /// the tools are stateless, so one instance serves every call.
    static let coreLocalFileAndTextTools: [AnyFeatureTool] =
        LocalFeatureTools.fileTools()
            + LocalFeatureTools.searchTools()
            + LocalFeatureTools.textTools()

    /// Descriptors of `coreLocalFileAndTextTools`, in the same order.
    public static let coreLocalFileAndTextDescriptors: [DirectToolDescriptor] =
        coreLocalFileAndTextTools.map(\.descriptor.toolDescriptor).map(DirectToolDescriptor.init)

    /// The non-mutating subset of `coreLocalFileAndTextDescriptors`; every
    /// Search tool only reads.
    public static var coreReadLocalFileAndTextDescriptors: [DirectToolDescriptor] {
        (
            LocalFeatureTools.readOnlyFileTools()
                + LocalFeatureTools.searchTools()
                + LocalFeatureTools.textTools()
        ).map(\.descriptor.toolDescriptor).map(DirectToolDescriptor.init)
    }

    public static var coreMutatingLocalFileAndTextDescriptors: [DirectToolDescriptor] {
        LocalFeatureTools.mutatingFileTools()
            .map(\.descriptor.toolDescriptor)
            .map(DirectToolDescriptor.init)
    }

    public static let memoryDescriptors: [DirectToolDescriptor] =
        MemoryTool.toolDescriptors.map(DirectToolDescriptor.init)

    public static let coreReadMemoryDescriptors: [DirectToolDescriptor] =
        MemoryTool.readOnlyToolDescriptors.map(DirectToolDescriptor.init)

    public static let coreMutatingMemoryDescriptors: [DirectToolDescriptor] =
        MemoryTool.mutatingToolDescriptors.map(DirectToolDescriptor.init)

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

    public static var coreReadTodoTaskDescriptors: [DirectToolDescriptor] {
        DirectTodoRuntime.readOnlyToolDescriptors
    }

    public static var coreMutatingTodoTaskDescriptors: [DirectToolDescriptor] {
        DirectTodoRuntime.mutatingToolDescriptors
    }

    public static var subAgentDescriptors: [DirectToolDescriptor] {
        DirectSubAgentRuntime.toolDescriptors
    }

    public static var coreReadSubAgentDescriptors: [DirectToolDescriptor] {
        DirectSubAgentRuntime.readOnlyToolDescriptors
    }

    public static var coreMutatingSubAgentDescriptors: [DirectToolDescriptor] {
        DirectSubAgentRuntime.mutatingToolDescriptors
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
        Self.decodedInputSchema(inputSchema)?.jsonObject
    }

    /// Decoded input schemas keyed by their JSON text. Every request payload
    /// serializes the schema of every offered tool; this way each distinct
    /// schema is decoded once per process. The cache is bounded: it is emptied
    /// before it would exceed `decodedInputSchemaLimit` entries. A schema that
    /// fails to decode is not cached.
    private static let decodedInputSchemas = Mutex<[String: JSONValue]>([:])
    private static let decodedInputSchemaLimit = 512

    private static func decodedInputSchema(_ inputSchema: String) -> JSONValue? {
        if let cached = decodedInputSchemas.withLock({ $0[inputSchema] }) {
            return cached
        }
        guard let data = inputSchema.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return nil
        }
        decodedInputSchemas.withLock { cache in
            if cache[inputSchema] == nil, cache.count >= decodedInputSchemaLimit {
                cache.removeAll(keepingCapacity: true)
            }
            cache[inputSchema] = decoded
        }
        return decoded
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
