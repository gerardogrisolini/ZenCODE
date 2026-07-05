//
//  TerminalToolSelection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public enum TerminalChatError: LocalizedError {
    case noInputReceived
    case noConfiguredModels
    case modelSelectionRequired
    case interactivePromptUnavailable

    public var errorDescription: String? {
        switch self {
        case .noInputReceived:
            return "No input received on stdin. Run ZenCODE from an interactive terminal, pipe a prompt, or pass --acp for ACP clients."
        case .noConfiguredModels:
            return "No models are configured for ZenCODE. Configure local or remote models in ZenCODE first."
        case .modelSelectionRequired:
            return "No model selected. Run ZenCODE in an interactive terminal and choose one with /models."
        case .interactivePromptUnavailable:
            return "Interactive prompt unavailable: no foreground controlling terminal is available for raw input."
        }
    }
}

public struct TerminalToolSelectionItem: Hashable, Sendable {
    public let key: String
    public let title: String
    public let detail: String?
    public let groupTitle: String?
    public let allowedToolNames: Set<String>
    public let aliases: Set<String>
    public let requiresWorkspaceAccess: Bool
    public let externalDiscoveryPrefixes: Set<String>

    public init(
        key: String,
        title: String,
        detail: String?,
        groupTitle: String?,
        allowedToolNames: Set<String>,
        aliases: Set<String> = [],
        requiresWorkspaceAccess: Bool = false,
        externalDiscoveryPrefixes: Set<String> = []
    ) {
        self.key = key
        self.title = title
        self.detail = detail
        self.groupTitle = groupTitle
        self.allowedToolNames = allowedToolNames
        self.aliases = aliases
        self.requiresWorkspaceAccess = requiresWorkspaceAccess
        self.externalDiscoveryPrefixes = externalDiscoveryPrefixes
    }

    public func allows(toolName: String) -> Bool {
        DirectToolExecutor.isAllowed(
            toolName,
            allowedToolNames: allowedToolNames
        )
    }
}

public enum TerminalToolSelectionCatalog {
    public static let featureBuilderKey = "feature.builder"
    public static let featurePackageKeyPrefix = "feature:"

    public static func featurePackageKey(id: String) -> String {
        "\(featurePackageKeyPrefix)\(id)"
    }

    public static func items(
        featureStatuses: [SwiftFeatureStatus],
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [TerminalToolSelectionItem] {
        let featureStatuses = mergedFeatureStatuses(
            featureStatuses,
            preconfiguredStatuses: preconfiguredFeatureSelectionStatuses(
                additionalDescriptors: additionalDescriptors
            )
        )
        return coreItems(additionalDescriptors: additionalDescriptors)
            + featurePackageItems(featureStatuses: featureStatuses)
    }

    public static func allowedToolNames(
        for selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        let selectedKeys = normalizedSelectionKeys(selectedKeys, items: items)
        guard !selectedKeys.isEmpty else {
            return []
        }
        return Set(
            items
                .filter { selectedKeys.contains($0.key) }
                .flatMap(\.allowedToolNames)
        )
    }

    public static func externalDiscoveryPrefixes(
        for selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        let selectedKeys = normalizedSelectionKeys(selectedKeys, items: items)
        return Set(
            items
                .filter { selectedKeys.contains($0.key) }
                .flatMap(\.externalDiscoveryPrefixes)
        )
    }

    public static func workspaceAccessSelectionKeys(
        for selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        let selectedKeys = normalizedSelectionKeys(selectedKeys, items: items)
        return Set(
            items
                .filter { selectedKeys.contains($0.key) && $0.requiresWorkspaceAccess }
                .map(\.key)
        )
    }

    public static func parseSelection(
        _ rawSelection: String,
        items: [TerminalToolSelectionItem]
    ) throws -> Set<String> {
        let tokens = rawSelection
            .replacingOccurrences(of: ",", with: " ")
            .split { $0.isWhitespace }
            .map(String.init)

        guard !tokens.isEmpty else {
            return []
        }

        if tokens.count == 1 {
            let normalizedToken = tokens[0].lowercased()
            if normalizedToken == "all" {
                return Set(items.map(\.key))
            }
            if ["none", "off", "clear", "disabled"].contains(normalizedToken) {
                return []
            }
        }

        var selectedKeys = Set<String>()
        for token in tokens {
            if let index = Int(token),
               items.indices.contains(index - 1) {
                selectedKeys.insert(items[index - 1].key)
                continue
            }
            let matchedKeys = selectionKeys(for: token, items: items)
            guard !matchedKeys.isEmpty else {
                throw TerminalToolSelectionError.unknownToken(token)
            }
            selectedKeys.formUnion(matchedKeys)
        }
        return selectedKeys
    }

    public static func normalizedSelectionKeys(
        _ rawKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        var normalizedKeys = Set<String>()
        for rawKey in rawKeys {
            let matchedKeys = selectionKeys(for: rawKey, items: items)
            if matchedKeys.isEmpty {
                normalizedKeys.insert(rawKey)
            } else {
                normalizedKeys.formUnion(matchedKeys)
            }
        }
        return normalizedKeys
    }

    public static func selectedKeyNames(
        _ selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> [String] {
        let normalizedKeys = normalizedSelectionKeys(selectedKeys, items: items)
        return items
            .filter { normalizedKeys.contains($0.key) }
            .map(\.key)
    }

    public static func selectionKeys(
        for rawToken: String,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        let trimmedToken = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            return []
        }
        if items.contains(where: { $0.key == trimmedToken }) {
            return [trimmedToken]
        }

        let token = normalizedLookupKey(trimmedToken)
        guard !token.isEmpty else {
            return []
        }

        let matchedKeys = Set(
            items.compactMap { item in
                let lookupKeys = Set(
                    ([item.key, item.title] + Array(item.aliases))
                        .map(normalizedLookupKey)
                )
                if lookupKeys.contains(token)
                    || item.key.lowercased().hasPrefix(trimmedToken.lowercased()) {
                    return item.key
                }
                return nil
            }
        )
        if !matchedKeys.isEmpty {
            return matchedKeys
        }

        return externalConnectorSelectionKeys(
            for: trimmedToken,
            items: items
        )
    }

    private static func externalConnectorSelectionKeys(
        for rawToken: String,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        let normalizedToken = normalizedLookupKey(rawToken)
        if normalizedToken == "xcode" || DirectMCPToolRuntime.isXcodeToolName(rawToken) {
            return featurePackageSelectionKeys(
                matchingAllowedToolNames: { name in
                    name == "Xcode" || name.hasPrefix("xcode.")
                },
                items: items
            )
        }

        if normalizedToken == "figma" || rawToken.hasPrefix("figma.") {
            return featurePackageSelectionKeys(
                matchingAllowedToolNames: { $0.hasPrefix("figma.") },
                items: items
            )
        }

        return []
    }

    private static func featurePackageSelectionKeys(
        matchingAllowedToolNames isMatch: (String) -> Bool,
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        Set(
            items.compactMap { item in
                item.allowedToolNames.contains(where: isMatch) ? item.key : nil
            }
        )
    }

    private static func coreItems(
        additionalDescriptors: [DirectToolDescriptor]
    ) -> [TerminalToolSelectionItem] {
        let descriptors = AgentToolSelection.selectableDescriptors(
            additionalDescriptors: additionalDescriptors
        )
        let descriptorNames = Set(descriptors.map(\.name))
        let coreGroup = "Core"

        let items = [
            TerminalToolSelectionItem(
                key: "shell",
                title: "Shell",
                detail: "Run shell commands in the workspace.",
                groupTitle: coreGroup,
                allowedToolNames: descriptorNames.filter { $0 == "local.exec" },
                aliases: ["bash", "sh", "zsh", "exec"],
                requiresWorkspaceAccess: true
            ),
            TerminalToolSelectionItem(
                key: "files",
                title: "Files",
                detail: "Read, write, edit, and move local files.",
                groupTitle: coreGroup,
                allowedToolNames: descriptorNames.filter {
                    $0.hasPrefix("local.") && $0 != "local.exec"
                },
                aliases: ["file", "local", "filesystem", "fs"],
                requiresWorkspaceAccess: true
            ),
            TerminalToolSelectionItem(
                key: "text",
                title: "Text",
                detail: "Inspect and transform local text files.",
                groupTitle: coreGroup,
                allowedToolNames: descriptorNames.filter { $0.hasPrefix("text.") },
                aliases: ["txt"],
                requiresWorkspaceAccess: true
            ),
            TerminalToolSelectionItem(
                key: "memory",
                title: "Memory",
                detail: "Manage memory notes and the session todo list.",
                groupTitle: coreGroup,
                allowedToolNames: descriptorNames.filter {
                    $0.hasPrefix("memory.") || $0.hasPrefix("todo.")
                },
                aliases: ["mem", "remember", "todo", "todos"],
                requiresWorkspaceAccess: true
            ),
            TerminalToolSelectionItem(
                key: "orchestration",
                title: "Sub-Agents",
                detail: "Delegate work to sub-agents and orchestrate tasks.",
                groupTitle: coreGroup,
                allowedToolNames: descriptorNames.filter {
                    $0.hasPrefix("agent.") || $0.hasPrefix("task.")
                },
                aliases: ["agents", "agent", "subagents", "sub-agents", "tasks", "task"]
            )
        ]

        return items.filter { !$0.allowedToolNames.isEmpty }
    }

    private static func featurePackageItems(
        featureStatuses: [SwiftFeatureStatus]
    ) -> [TerminalToolSelectionItem] {
        featureStatuses
            .filter { $0.enabled && $0.available }
            .sorted { lhs, rhs in
                featureTitle(lhs).localizedStandardCompare(featureTitle(rhs)) == .orderedAscending
            }
            .map { status in
                let allowedNames = featurePackageAllowedNames(from: [status])
                return TerminalToolSelectionItem(
                    key: featurePackageKey(id: status.id),
                    title: featureTitle(status),
                    detail: featureDetail(status),
                    groupTitle: "Feature Packages",
                    allowedToolNames: allowedNames,
                    aliases: featureAliases(status),
                    requiresWorkspaceAccess: requiresWorkspaceAccess(featureStatus: status),
                    externalDiscoveryPrefixes: externalDiscoveryPrefixes(from: [status])
                )
            }
    }

    private static func preconfiguredFeatureSelectionStatuses(
        additionalDescriptors: [DirectToolDescriptor]
    ) -> [SwiftFeatureStatus] {
        let descriptors = AgentToolSelection.selectableDescriptors(
            additionalDescriptors: additionalDescriptors
        )
        return [
            bundledFeatureSelectionStatus(
                id: "search-tools",
                tools: descriptors.filter { $0.name.hasPrefix("search.") }.map(\.name)
            ),
            bundledFeatureSelectionStatus(
                id: "web-tools",
                tools: descriptors.filter { $0.name.hasPrefix("web.") }.map(\.name)
            ),
            bundledFeatureSelectionStatus(
                id: "git-tools",
                tools: descriptors.filter { $0.name.hasPrefix("git.") }.map(\.name)
            ),
            bundledFeatureSelectionStatus(
                id: "swift-tools",
                tools: descriptors.filter { $0.name.hasPrefix("swift.") }.map(\.name)
            ),
            bundledFeatureSelectionStatus(
                id: "xcode-tools",
                tools: descriptors.filter { $0.name.hasPrefix("xcode.") }.map(\.name),
                toolNamePrefixes: ["xcode."]
            ),
            bundledFeatureSelectionStatus(
                id: "figma-tools",
                tools: descriptors.filter { $0.name.hasPrefix("figma.") }.map(\.name),
                toolNamePrefixes: ["figma."]
            )
        ].filter { !$0.tools.isEmpty || !$0.toolNamePrefixes.isEmpty }
    }

    private static func bundledFeatureDescription(id: String) -> String? {
        SwiftFeatureRuntime.bundledFeatureDefinitions()
            .first { $0.id == id }?
            .description?
            .nilIfBlank
    }

    private static func bundledFeatureSelectionStatus(
        id: String,
        tools: [String],
        toolNamePrefixes: [String] = []
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: id,
            displayName: nil,
            description: bundledFeatureDescription(id: id),
            source: .bundled,
            enabled: true,
            available: true,
            executablePath: "",
            manifestPath: nil,
            tools: tools,
            toolNamePrefixes: toolNamePrefixes,
            toolNameAliases: [],
            discoversToolsAtRuntime: !toolNamePrefixes.isEmpty,
            build: nil,
            generated: nil,
            issue: nil
        )
    }

    private static func mergedFeatureStatuses(
        _ statuses: [SwiftFeatureStatus],
        preconfiguredStatuses: [SwiftFeatureStatus]
    ) -> [SwiftFeatureStatus] {
        var statusesByID = Dictionary(uniqueKeysWithValues: preconfiguredStatuses.map { ($0.id, $0) })
        for status in statuses {
            if let preconfiguredStatus = statusesByID[status.id] {
                statusesByID[status.id] = mergedFeatureStatus(
                    status,
                    with: preconfiguredStatus
                )
            } else {
                statusesByID[status.id] = status
            }
        }
        return Array(statusesByID.values)
    }

    private static func mergedFeatureStatus(
        _ status: SwiftFeatureStatus,
        with preconfiguredStatus: SwiftFeatureStatus
    ) -> SwiftFeatureStatus {
        SwiftFeatureStatus(
            id: status.id,
            displayName: status.displayName ?? preconfiguredStatus.displayName,
            description: status.description ?? preconfiguredStatus.description,
            source: status.source,
            enabled: status.enabled,
            available: status.available,
            executablePath: status.executablePath,
            manifestPath: status.manifestPath,
            tools: sortedUnique(status.tools + preconfiguredStatus.tools),
            toolNamePrefixes: sortedUnique(status.toolNamePrefixes + preconfiguredStatus.toolNamePrefixes),
            toolNameAliases: sortedUnique(status.toolNameAliases + preconfiguredStatus.toolNameAliases),
            discoversToolsAtRuntime: status.discoversToolsAtRuntime || preconfiguredStatus.discoversToolsAtRuntime,
            build: status.build ?? preconfiguredStatus.build,
            generated: status.generated ?? preconfiguredStatus.generated,
            issue: status.issue ?? preconfiguredStatus.issue
        )
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Set(values.compactMap(\.nilIfBlank)).sorted()
    }

    private static func featurePackageAllowedNames(
        from statuses: [SwiftFeatureStatus]
    ) -> Set<String> {
        Set(
            statuses.flatMap { status in
                status.tools + status.toolNamePrefixes
            }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }

    private static func externalDiscoveryPrefixes(
        from statuses: [SwiftFeatureStatus]
    ) -> Set<String> {
        Set(
            statuses.flatMap(\.toolNamePrefixes).filter {
                $0 == "xcode." || $0 == "figma."
            }
        )
    }

    private static func requiresWorkspaceAccess(
        featureStatus status: SwiftFeatureStatus
    ) -> Bool {
        if status.source == .generated {
            return true
        }
        let localPrefixes = ["local.", "search.", "git.", "text.", "memory.", "todo."]
        return (status.tools + status.toolNamePrefixes).contains { name in
            localPrefixes.contains { name.hasPrefix($0) }
        }
    }

    private static func featureTitle(_ status: SwiftFeatureStatus) -> String {
        if let displayName = status.displayName?.nilIfBlank {
            return displayName
        }
        var name = status.id
        if name.hasPrefix("mlx-") {
            name.removeFirst("mlx-".count)
        }
        if name.hasSuffix("-tools") {
            name.removeLast("-tools".count)
        }
        return name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
    }

    private static func featureDetail(_ status: SwiftFeatureStatus) -> String {
        if let description = status.description?.nilIfBlank {
            return description
        }
        return status.source == .bundled ? "bundled Swift feature package" : "generated Swift feature package"
    }

    private static func featureAliases(_ status: SwiftFeatureStatus) -> Set<String> {
        var aliases = Set<String>()
        aliases.insert(status.id)
        aliases.insert(featureTitle(status))
        aliases.formUnion(status.tools)
        aliases.formUnion(status.toolNamePrefixes)
        aliases.formUnion(status.toolNameAliases)
        switch status.id {
        case "search-tools":
            aliases.formUnion(["search", "grep", "glob"])
        case "web-tools":
            aliases.formUnion(["web", "browser"])
        case "git-tools":
            aliases.insert("git")
        case "swift-tools":
            aliases.formUnion(["swift", "build", "test"])
        case "xcode-tools":
            aliases.insert("xcode")
        case "figma-tools":
            aliases.insert("figma")
        default:
            break
        }
        return aliases
    }

    private static func normalizedLookupKey(_ value: String) -> String {
        let foldedValue = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let characters = foldedValue.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        return String(characters)
            .replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
