//
//  SwiftFeatureManifestModels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/06/26.
//
import Foundation

public enum SwiftFeatureBundleSource: String, Codable, Hashable, Sendable {
    case bundled
    case generated
}

public struct SwiftFeatureBundle: Hashable, Sendable {
    public let id: String
    public let executableURL: URL
    public let tools: [ToolDescriptor]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let source: SwiftFeatureBundleSource

    public init(
        id: String,
        executableURL: URL,
        tools: [ToolDescriptor],
        toolNamePrefixes: [String] = [],
        toolNameAliases: [String] = [],
        discoversToolsAtRuntime: Bool = false,
        source: SwiftFeatureBundleSource = .generated
    ) {
        self.id = id.nilIfBlank ?? executableURL.lastPathComponent
        self.executableURL = executableURL.standardizedFileURL
        self.tools = ToolDescriptor.canonicalized(tools)
        self.toolNamePrefixes = toolNamePrefixes
        self.toolNameAliases = toolNameAliases
        self.discoversToolsAtRuntime = discoversToolsAtRuntime
        self.source = source
    }

    public func contains(toolName: String) -> Bool {
        tools.contains { $0.name == toolName }
            || toolNameAliases.contains(toolName)
            || toolNamePrefixes.contains { toolName.hasPrefix($0) }
    }

    public func isRelevant(allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }

        guard !allowedToolNames.isEmpty else {
            return false
        }

        if tools.contains(where: { DirectToolExecutor.isAllowed($0.name, allowedToolNames: allowedToolNames) }) {
            return true
        }

        if toolNameAliases.contains(where: { DirectToolExecutor.isAllowed($0, allowedToolNames: allowedToolNames) }) {
            return true
        }

        for prefix in toolNamePrefixes {
            if allowedToolNames.contains(prefix) {
                return true
            }
            if allowedToolNames.contains(where: { allowedToolName in
                allowedToolName.hasPrefix(prefix) || prefix.hasPrefix(allowedToolName)
            }) {
                return true
            }
        }

        if allowedToolNames.contains(SwiftFeatureRuntime.featurePackageToolsAllowedName) {
            return true
        }

        return false
    }
}

public struct SwiftFeatureManifest: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: String
    public let displayName: String?
    public let description: String?
    public let executable: String
    public let enabled: Bool
    public let tools: [SwiftFeatureToolManifest]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case schema_version
        case id
        case name
        case displayName
        case display_name
        case description
        case executable
        case binary
        case enabled
        case tools
        case toolNamePrefixes
        case tool_name_prefixes
        case toolNameAliases
        case tool_name_aliases
        case discoversToolsAtRuntime
        case discovers_tools_at_runtime
        case build
        case generated
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? container.decodeIfPresent(Int.self, forKey: .schema_version)
            ?? Self.currentSchemaVersion
        self.id = try container.decode(String.self, forKey: .id)
        self.displayName = try Self.firstString(
            in: container,
            keys: [.displayName, .display_name, .name]
        )?.nilIfBlank
        self.description = try container.decodeIfPresent(String.self, forKey: .description)?.nilIfBlank
        self.executable = try container.decodeIfPresent(String.self, forKey: .executable)
            ?? container.decode(String.self, forKey: .binary)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.tools = try container.decode([SwiftFeatureToolManifest].self, forKey: .tools)
        self.toolNamePrefixes = try Self.stringArray(
            in: container,
            keys: [.toolNamePrefixes, .tool_name_prefixes]
        )
        self.toolNameAliases = try Self.stringArray(
            in: container,
            keys: [.toolNameAliases, .tool_name_aliases]
        )
        self.discoversToolsAtRuntime = try container.decodeIfPresent(
            Bool.self,
            forKey: .discoversToolsAtRuntime
        ) ?? container.decodeIfPresent(
            Bool.self,
            forKey: .discovers_tools_at_runtime
        ) ?? false
        self.build = try container.decodeIfPresent(SwiftFeatureBuildManifest.self, forKey: .build)
        self.generated = try container.decodeIfPresent(SwiftFeatureGeneratedManifest.self, forKey: .generated)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(executable, forKey: .executable)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(tools, forKey: .tools)
        if !toolNamePrefixes.isEmpty {
            try container.encode(toolNamePrefixes, forKey: .toolNamePrefixes)
        }
        if !toolNameAliases.isEmpty {
            try container.encode(toolNameAliases, forKey: .toolNameAliases)
        }
        if discoversToolsAtRuntime {
            try container.encode(discoversToolsAtRuntime, forKey: .discoversToolsAtRuntime)
        }
        try container.encodeIfPresent(build, forKey: .build)
        try container.encodeIfPresent(generated, forKey: .generated)
    }

    private static func firstString(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> String? {
        for key in keys {
            if let value = try container.decodeIfPresent(String.self, forKey: key) {
                return value
            }
        }
        return nil
    }

    private static func stringArray(
        in container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) throws -> [String] {
        for key in keys {
            if let values = try container.decodeIfPresent([String].self, forKey: key) {
                return normalizedStrings(values)
            }
        }
        return []
    }

    private static func normalizedStrings(_ values: [String]) -> [String] {
        Array(Set(values.compactMap { $0.nilIfBlank })).sorted()
    }
}

public struct SwiftFeatureBuildManifest: Codable, Sendable {
    public let system: String
    public let packagePath: String?
    public let product: String?
    public let configuration: String?
    public let executablePath: String?
    public let arguments: [String]

    private enum CodingKeys: String, CodingKey {
        case system
        case packagePath
        case package_path
        case product
        case configuration
        case executablePath
        case executable_path
        case arguments
    }

    public init(
        system: String = "swiftpm",
        packagePath: String? = nil,
        product: String? = nil,
        configuration: String? = "release",
        executablePath: String? = nil,
        arguments: [String] = []
    ) {
        self.system = system.nilIfBlank ?? "swiftpm"
        self.packagePath = packagePath?.nilIfBlank
        self.product = product?.nilIfBlank
        self.configuration = configuration?.nilIfBlank
        self.executablePath = executablePath?.nilIfBlank
        self.arguments = arguments.compactMap { $0.nilIfBlank }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            system: try container.decodeIfPresent(String.self, forKey: .system) ?? "swiftpm",
            packagePath: try container.decodeIfPresent(String.self, forKey: .packagePath)
                ?? container.decodeIfPresent(String.self, forKey: .package_path),
            product: try container.decodeIfPresent(String.self, forKey: .product),
            configuration: try container.decodeIfPresent(String.self, forKey: .configuration) ?? "release",
            executablePath: try container.decodeIfPresent(String.self, forKey: .executablePath)
                ?? container.decodeIfPresent(String.self, forKey: .executable_path),
            arguments: try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(system, forKey: .system)
        try container.encodeIfPresent(packagePath, forKey: .packagePath)
        try container.encodeIfPresent(product, forKey: .product)
        try container.encodeIfPresent(configuration, forKey: .configuration)
        try container.encodeIfPresent(executablePath, forKey: .executablePath)
        if !arguments.isEmpty {
            try container.encode(arguments, forKey: .arguments)
        }
    }
}

public struct SwiftFeatureGeneratedManifest: Codable, Sendable {
    public let by: String?
    public let prompt: String?
    public let createdAt: String?

    private enum CodingKeys: String, CodingKey {
        case by
        case prompt
        case createdAt
        case created_at
    }

    public init(
        by: String? = nil,
        prompt: String? = nil,
        createdAt: String? = nil
    ) {
        self.by = by?.nilIfBlank
        self.prompt = prompt?.nilIfBlank
        self.createdAt = createdAt?.nilIfBlank
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            by: try container.decodeIfPresent(String.self, forKey: .by),
            prompt: try container.decodeIfPresent(String.self, forKey: .prompt),
            createdAt: try container.decodeIfPresent(String.self, forKey: .createdAt)
                ?? container.decodeIfPresent(String.self, forKey: .created_at)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(by, forKey: .by)
        try container.encodeIfPresent(prompt, forKey: .prompt)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

public struct SwiftFeatureToolManifest: Codable, Sendable {
    public let name: String
    public let title: String?
    public let description: String
    public let inputSchema: String
    public let outputSchema: String?

    private enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case inputSchema
        case input_schema
        case outputSchema
        case output_schema
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)?.nilIfBlank
        self.description = try container.decode(String.self, forKey: .description)
        self.inputSchema = try Self.schemaString(
            for: container,
            primaryKey: .inputSchema,
            alternateKey: .input_schema
        ) ?? "{}"
        self.outputSchema = try Self.schemaString(
            for: container,
            primaryKey: .outputSchema,
            alternateKey: .output_schema
        )?.nilIfBlank
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(description, forKey: .description)
        try container.encode(inputSchema, forKey: .inputSchema)
        try container.encodeIfPresent(outputSchema, forKey: .outputSchema)
    }

    public var toolDescriptor: ToolDescriptor {
        ToolDescriptor(
            name: name,
            title: title,
            description: description,
            inputSchema: inputSchema,
            outputSchema: outputSchema
        )
    }

    private static func schemaString(
        for container: KeyedDecodingContainer<CodingKeys>,
        primaryKey: CodingKeys,
        alternateKey: CodingKeys
    ) throws -> String? {
        for key in [primaryKey, alternateKey] {
            if let value = try? container.decodeIfPresent(JSONValue.self, forKey: key) {
                switch value {
                case let .string(schema):
                    return schema
                default:
                    return value.prettyPrinted()
                }
            }
        }
        return nil
    }
}

public struct SwiftFeatureRecord: Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let executableURL: URL
    public let manifestURL: URL?
    public let manifestEnabled: Bool
    public let executableAvailable: Bool
    public let tools: [ToolDescriptor]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let issue: String?

    public var enabled: Bool {
        manifestEnabled && executableAvailable
    }
}

public struct SwiftFeatureStatus: Codable, Sendable {
    public let id: String
    public let displayName: String?
    public let description: String?
    public let source: SwiftFeatureBundleSource
    public let enabled: Bool
    public let available: Bool
    public let executablePath: String
    public let manifestPath: String?
    public let tools: [String]
    public let toolNamePrefixes: [String]
    public let toolNameAliases: [String]
    public let discoversToolsAtRuntime: Bool
    public let toolCount: Int
    public let build: SwiftFeatureBuildManifest?
    public let generated: SwiftFeatureGeneratedManifest?
    public let issue: String?

    public init(
        id: String,
        displayName: String?,
        description: String?,
        source: SwiftFeatureBundleSource,
        enabled: Bool,
        available: Bool,
        executablePath: String,
        manifestPath: String?,
        tools: [String],
        toolNamePrefixes: [String],
        toolNameAliases: [String],
        discoversToolsAtRuntime: Bool,
        build: SwiftFeatureBuildManifest?,
        generated: SwiftFeatureGeneratedManifest?,
        issue: String?
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.source = source
        self.enabled = enabled
        self.available = available
        self.executablePath = executablePath
        self.manifestPath = manifestPath
        self.tools = tools
        self.toolNamePrefixes = toolNamePrefixes
        self.toolNameAliases = toolNameAliases
        self.discoversToolsAtRuntime = discoversToolsAtRuntime
        self.toolCount = tools.count
        self.build = build
        self.generated = generated
        self.issue = issue
    }
}

public struct SwiftFeatureValidationReport: Codable, Sendable {
    public let ok: Bool
    public let id: String?
    public let manifestPath: String
    public let executablePath: String?
    public let errors: [String]
    public let warnings: [String]
    public let tools: [String]

    public init(
        id: String?,
        manifestPath: String,
        executablePath: String?,
        errors: [String],
        warnings: [String],
        tools: [String]
    ) {
        self.ok = errors.isEmpty
        self.id = id
        self.manifestPath = manifestPath
        self.executablePath = executablePath
        self.errors = errors
        self.warnings = warnings
        self.tools = tools
    }
}

public struct SwiftFeatureBuildReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let command: [String]
    public let workingDirectory: String
    public let executablePath: String
    public let exitCode: Int32
    public let timedOut: Bool
    public let stdout: String
    public let stderr: String
}

public struct SwiftFeatureScaffoldReport: Codable, Sendable {
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let packagePath: String
    public let sourcePath: String
    public let toolName: String
}

public struct SwiftFeatureInstallReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let sourcePath: String
    public let destinationPath: String
    public let manifestPath: String
    public let copied: Bool
    public let built: Bool
    public let enabled: Bool
    public let validation: SwiftFeatureValidationReport
    public let build: SwiftFeatureBuildReport?
}

public struct SwiftFeatureDeleteReport: Codable, Sendable {
    public let ok: Bool
    public let id: String
    public let directoryPath: String
    public let manifestPath: String
    public let removed: Bool
    public let wasEnabled: Bool
}

public struct SwiftFeatureState: Codable, Sendable {
    public static let currentVersion = 1
    public static let defaultDisabledBundledFeatureIDs: Set<String> = [
        "jira-tools"
    ]

    public var version: Int
    public var disabledBundledFeatureIDs: [String]
    public var enabledBundledFeatureIDs: [String]

    private enum CodingKeys: String, CodingKey {
        case version
        case disabledBundledFeatureIDs
        case enabledBundledFeatureIDs
    }

    public init(
        version: Int = Self.currentVersion,
        disabledBundledFeatureIDs: [String] = [],
        enabledBundledFeatureIDs: [String] = []
    ) {
        self.version = version
        self.disabledBundledFeatureIDs = Array(
            Set(disabledBundledFeatureIDs.compactMap { $0.nilIfBlank })
        ).sorted()
        self.enabledBundledFeatureIDs = Array(
            Set(enabledBundledFeatureIDs.compactMap { $0.nilIfBlank })
        ).sorted()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            version: try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion,
            disabledBundledFeatureIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .disabledBundledFeatureIDs
            ) ?? [],
            enabledBundledFeatureIDs: try container.decodeIfPresent(
                [String].self,
                forKey: .enabledBundledFeatureIDs
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(disabledBundledFeatureIDs, forKey: .disabledBundledFeatureIDs)
        try container.encode(enabledBundledFeatureIDs, forKey: .enabledBundledFeatureIDs)
    }

    public func bundledFeatureIsEnabled(id: String) -> Bool {
        guard !disabledBundledFeatureIDs.contains(id) else {
            return false
        }
        if Self.defaultDisabledBundledFeatureIDs.contains(id) {
            return enabledBundledFeatureIDs.contains(id)
        }
        return true
    }
}
