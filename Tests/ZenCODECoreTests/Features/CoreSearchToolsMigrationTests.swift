//
//  CoreSearchToolsMigrationTests.swift
//  ZenCODE
//
//  Characterizes the migration of `search.glob`, `search.grep`, and
//  `search.locate` from the retired optional `search-tools` feature package
//  into the core of `zen`.
//

import Foundation
@testable import ZenCODECore
import Testing
import ZenPackageMetadata

@Suite(.serialized)
struct CoreSearchToolsMigrationTests {
    private static let searchToolNames: Set<String> = [
        "search.glob",
        "search.grep",
        "search.locate"
    ]
    private static let retiredFeatureID = "search-tools"
    private static let legacyPackageKey = TerminalToolSelectionCatalog.featurePackageKey(id: retiredFeatureID)

    // MARK: - Core catalog

    @Test
    func searchToolsAreCoreReadOnlyToolsExecutedInProcess() {
        let names: (([DirectToolDescriptor]) -> Set<String>) = { Set($0.map(\.name)) }

        #expect(names(DirectToolCatalog.localSearchDescriptors) == Self.searchToolNames)
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.baseDescriptors)))
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.selectableDescriptors)))
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.coreDescriptors)))
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.coreLocalFileAndTextDescriptors)))
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.coreReadDescriptors)))
        #expect(Self.searchToolNames.isSubset(of: names(DirectToolCatalog.coreReadLocalFileAndTextDescriptors)))
        #expect(Self.searchToolNames.isDisjoint(with: names(DirectToolCatalog.coreMutatingDescriptors)))
        #expect(Self.searchToolNames.isDisjoint(with: names(DirectToolCatalog.coreMutatingLocalFileAndTextDescriptors)))
        for name in Self.searchToolNames {
            // Core local tools are executed in-process and are not opaque
            // mutations for the operation file-change evidence.
            #expect(DirectToolExecutor.isCoreLocalFileOrTextToolName(name))
        }
        #expect(SwiftFeatureRuntime.bundledFeatureDefinition(id: Self.retiredFeatureID) == nil)
        #expect(ZenBundledFeatureCatalog.feature(id: Self.retiredFeatureID) == nil)
        #expect(SwiftBundledFeatureCatalog.retiredFeatureIDs == [Self.retiredFeatureID])
    }

    @Test
    func readOnlyProfileKeepsCoreSearchTools() {
        let profile = AgentProfile(
            id: "read-only-search",
            name: "Read Only Search",
            readOnly: true,
            role: .developer
        )

        #expect(profile.resolvedAllowedToolNames(["search."]) == Self.searchToolNames)
        #expect(profile.resolvedAllowedToolNames(Self.searchToolNames) == Self.searchToolNames)
    }

    // MARK: - /tools selection

    @Test
    func toolsSelectionExposesTheCoreSearchGroupWithLegacyAliases() throws {
        let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
        let item = try #require(items.first { $0.key == "search" })

        #expect(item.title == "Search")
        #expect(item.groupTitle == "Core")
        #expect(item.detail == "Find files by glob and search file contents.")
        #expect(item.requiresWorkspaceAccess)
        #expect(item.allowedToolNames == Self.searchToolNames)
        #expect(item.aliases.isSuperset(of: ["grep", "glob", Self.retiredFeatureID, Self.legacyPackageKey]))
        #expect(!items.contains { $0.key == Self.legacyPackageKey })

        let coreKeys = items.filter { $0.groupTitle == "Core" }.map(\.key)
        let filesIndex = try #require(coreKeys.firstIndex(of: "files"))
        let searchIndex = try #require(coreKeys.firstIndex(of: "search"))
        let textIndex = try #require(coreKeys.firstIndex(of: "text"))
        #expect(filesIndex + 1 == searchIndex)
        #expect(searchIndex + 1 == textIndex)

        for reference in [
            "search",
            "Search",
            "grep",
            "glob",
            Self.retiredFeatureID,
            Self.legacyPackageKey,
            "Feature:Search-Tools"
        ] {
            #expect(
                TerminalToolSelectionCatalog.normalizedSelectionKeys([reference], items: items) == ["search"],
                "\(reference) should resolve to the core search group"
            )
        }
        #expect(
            try TerminalToolSelectionCatalog.parseSelection(
                "files \(Self.legacyPackageKey) text",
                items: items
            ) == ["files", "search", "text"]
        )
        #expect(
            TerminalToolSelectionCatalog.allowedToolNames(
                for: [Self.legacyPackageKey],
                items: items
            ) == Self.searchToolNames
        )
        #expect(
            TerminalToolSelectionCatalog.workspaceAccessSelectionKeys(
                for: [Self.retiredFeatureID],
                items: items
            ) == ["search"]
        )
    }

    @Test(arguments: ["feature:search-tools", "search-tools"])
    func legacySearchFeatureReferenceInAProfileGrantsCoreSearchTools(reference: String) {
        let profile = AgentProfile(
            id: "legacy-search",
            name: "Legacy Search",
            role: .developer,
            tools: [reference]
        )
        let readOnlyProfile = AgentProfile(
            id: "legacy-search-read-only",
            name: "Legacy Search Read Only",
            readOnly: true,
            role: .developer,
            tools: [reference]
        )

        let allowed = profile.allowedToolNames(featureStatuses: [])
        let readOnlyAllowed = readOnlyProfile.allowedToolNames(featureStatuses: [])

        #expect(allowed == Self.searchToolNames)
        #expect(readOnlyAllowed == Self.searchToolNames)
        for name in Self.searchToolNames {
            #expect(DirectToolExecutor.isAllowed(name, allowedToolNames: allowed))
        }
    }

    // MARK: - Profile persistence

    @Test
    func savingProfilesRewritesLegacySearchReferencesWithoutDuplicates() {
        let cases: [(tools: [String], expected: [String])] = [
            (["files", "feature:search-tools", "text"], ["files", "search", "text"]),
            (["search-tools"], ["search"]),
            (["Feature:Search-Tools"], ["search"]),
            (["search", "feature:search-tools"], ["search"]),
            (["feature:search-tools", "search"], ["search"]),
            (["feature:search-tools", "files", "search-tools", "search", "text"], ["search", "files", "text"]),
            (["shell", "files", "search", "text"], ["shell", "files", "search", "text"])
        ]

        for testCase in cases {
            let profile = AgentProfile(
                id: "profile",
                name: "Profile",
                role: .developer,
                tools: testCase.tools
            )
            #expect(
                AgentProfileStore.normalizedAgentForSave(profile).tools == testCase.expected,
                "\(testCase.tools)"
            )
        }
    }

    @Test
    func legacySearchReferencesAreRewrittenOnlyWhenProfilesAreSaved() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-search-profiles-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        try AppStorageDirectory.withSupportDirectoryURL(supportURL) {
            let manifestURL = AgentProfileStore.agentsManifestURL()
            #expect(manifestURL.path.hasPrefix(supportURL.standardizedFileURL.path))
            let original = Data(
                #"{"version":1,"agents":[{"id":"developer","name":"Developer","role":"developer","tools":["shell","feature:search-tools","search","text"]}]}"#.utf8
            )
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try original.write(to: manifestURL)

            // Loading and the startup check keep the persisted reference.
            let loaded = try AgentProfileStore.loadRequired()
            try AgentProfileStore.ensureDefaultManifestExists()
            #expect(loaded.first?.tools == ["shell", "feature:search-tools", "search", "text"])
            #expect(try Data(contentsOf: manifestURL) == original)
            let developer = try #require(loaded.first)
            #expect(
                Self.searchToolNames.isSubset(
                    of: developer.allowedToolNames(featureStatuses: [])
                )
            )

            // Saving rewrites the legacy key to `search`, deduplicated.
            try AgentProfileStore.save(loaded)
            let saved = try JSONDecoder().decode(
                AgentProfileManifest.self,
                from: Data(contentsOf: manifestURL)
            )
            #expect(saved.agents.first?.tools == ["shell", "search", "text"])
            let savedText = try String(contentsOf: manifestURL, encoding: .utf8)
            #expect(!savedText.contains(Self.retiredFeatureID))
        }
    }

    // MARK: - Installed copies

    @Test(arguments: [false, true])
    func installedSearchToolsCopyIsIgnoredAndLeftOnDisk(adopted: Bool) async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-search-installed-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }

        try await AppStorageDirectory.withSupportDirectoryURL(supportURL) {
            let featureRootURL = SwiftFeatureRegistry.appFeatureRootURL()
            #expect(featureRootURL.path == supportURL.appendingPathComponent("features").path)

            let markerURL = supportURL.appendingPathComponent("retired-copy-ran")
            let copyURL = featureRootURL.appendingPathComponent(Self.retiredFeatureID, isDirectory: true)
            try Self.writeFeature(
                at: copyURL,
                id: Self.retiredFeatureID,
                toolName: "search.glob",
                markerURL: markerURL,
                adoptedFrom: adopted ? Self.retiredFeatureID : nil
            )
            // A regular generated feature next to the retired copy proves the
            // feature root is actually scanned.
            try Self.writeFeature(
                at: featureRootURL.appendingPathComponent("control-fixture", isDirectory: true),
                id: "control-fixture",
                toolName: "control.echo",
                markerURL: nil,
                adoptedFrom: nil
            )
            let snapshot = try Self.directorySnapshot(copyURL)

            // Discovery and every listing skip the retired copy.
            #expect(SwiftFeatureRegistry.discoverFeatureRecords().map(\.id) == ["control-fixture"])
            #expect(SwiftFeatureRegistry.featureRecord(id: Self.retiredFeatureID) == nil)
            #expect(SwiftFeatureRegistry.discoverFeatureBundles().map(\.id) == ["control-fixture"])
            let statuses = SwiftFeatureRuntime.defaultFeatureStatuses()
            #expect(statuses.contains { $0.id == "control-fixture" })
            #expect(!statuses.contains { $0.id == Self.retiredFeatureID })
            #expect(!statuses.contains { $0.adoptedFrom == Self.retiredFeatureID })
            #expect(!SwiftFeatureRuntime.defaultFeatureBundles().contains { $0.id == Self.retiredFeatureID })
            #expect(!SwiftFeatureRuntime.optionalFeatures().contains { $0.id == Self.retiredFeatureID })
            #expect(SwiftFeatureRuntime.defaultFeatureToolDescriptors(includeDisabled: true).allSatisfy {
                $0.name != "search.glob" || $0.description != "Retired copy"
            })

            let runtime = SwiftFeatureRuntime()
            let runtimeStatuses = await runtime.featureStatuses(
                includeTools: true,
                includeDisabled: true,
                discoverRuntimeTools: true
            )
            #expect(!runtimeStatuses.contains { $0.id == Self.retiredFeatureID })
            #expect(!(await runtime.optionalFeatures()).contains { $0.id == Self.retiredFeatureID })
            let list = try await runtime.executeManagementTool(
                toolCall: Self.managementCall("feature.list", arguments: [:])
            )
            #expect(list.contains("control-fixture"))
            #expect(!list.contains(Self.retiredFeatureID))
            #expect(!(await runtime.canExecute(toolName: "search.glob")))

            // Management by id never reaches (nor modifies) the copy.
            for (name, expectedError) in [
                ("feature.disable", "Unknown Swift feature: search-tools."),
                ("feature.delete", "Unknown generated Swift feature: search-tools."),
                ("feature.edit", "Unknown editable Swift feature: search-tools.")
            ] {
                do {
                    _ = try await runtime.executeManagementTool(
                        toolCall: Self.managementCall(name, arguments: ["id": Self.retiredFeatureID])
                    )
                    Issue.record("\(name) unexpectedly accepted the retired search-tools copy.")
                } catch {
                    #expect(error.localizedDescription == expectedError)
                }
            }

            // `search.*` run in the core, never in the installed copy.
            let workspaceURL = supportURL.appendingPathComponent("workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
            try "let value = 1\n".write(
                to: workspaceURL.appendingPathComponent("Example.swift"),
                atomically: true,
                encoding: .utf8
            )
            let executor = DirectToolExecutor(
                swiftFeatureRuntime: runtime,
                subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
            )
            let result = await executor.execute(
                sessionID: "core-search-installed-copy",
                toolCall: DirectAgentToolCall(
                    id: "core-search-glob",
                    name: "search.glob",
                    argumentsObject: ["pattern": "*.swift"],
                    argumentsJSON: #"{"pattern":"*.swift"}"#
                ),
                workingDirectory: workspaceURL,
                allowedToolNames: Self.searchToolNames
            )
            await executor.shutdown()
            await runtime.shutdown()

            #expect(result.status == .completed)
            #expect(result.output.contains("Example.swift"))
            #expect(!FileManager.default.fileExists(atPath: markerURL.path))
            #expect(try Self.directorySnapshot(copyURL) == snapshot)
        }
    }

    // MARK: - Optional installation

    @Test
    func installingTheRetiredSearchToolsFeatureFailsAsAnUnknownOptionalFeature() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-search-install-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        do {
            _ = try await runtime.installOptionalFeature(id: Self.retiredFeatureID)
            Issue.record("Expected installing search-tools to fail.")
        } catch {
            #expect(error.localizedDescription == "Unknown optional Swift feature: search-tools.")
        }
        #expect(!SwiftFeatureRuntime.optionalFeatures(searchRoots: [rootURL]).contains {
            $0.id == Self.retiredFeatureID
        })
        #expect(!FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent(Self.retiredFeatureID).path
        ))
    }

    // MARK: - MCP bridge prefix

    @Test(arguments: ["search.", "search", "search.remote."])
    func mcpBridgeScaffoldRejectsTheCoreSearchToolPrefix(toolPrefix: String) async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("core-search-mcp-prefix-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let normalizedPrefix = SwiftFeatureRuntime.normalizedToolPrefix(toolPrefix)
        #expect(throws: (any Error).self) {
            try SwiftFeatureRuntime.validateMCPBridgeToolPrefix(normalizedPrefix)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        do {
            _ = try await runtime.executeManagementTool(
                toolCall: Self.managementCall(
                    "feature.scaffold",
                    arguments: [
                        "id": "search-mcp",
                        "template": "mcp-bridge",
                        "toolPrefix": toolPrefix,
                        "endpointURL": "https://mcp.example.com/tools"
                    ]
                )
            )
            Issue.record("Expected feature.scaffold to reject the core search. prefix.")
        } catch {
            #expect(
                error.localizedDescription
                    == "Tool prefix '\(normalizedPrefix)' conflicts with a core tool namespace."
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("search-mcp").path
        ))
    }

    @Test
    func mcpBridgePrefixesOutsideCoreNamespacesRemainAccepted() throws {
        for prefix in ["linear.", "searchx.", "research."] {
            try SwiftFeatureRuntime.validateMCPBridgeToolPrefix(prefix)
        }
    }

    // MARK: - Helpers

    private static func managementCall(
        _ name: String,
        arguments: [String: Any]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "\(name)-call",
            name: name,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
    }

    private static func writeFeature(
        at directoryURL: URL,
        id: String,
        toolName: String,
        markerURL: URL?,
        adoptedFrom: String?
    ) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let marker = markerURL.map { "touch '\($0.path)'\n" } ?? ""
        let executableURL = directoryURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        \(marker)if [ "$1" = "--invoke" ]; then
          cat >/dev/null
          printf '{"ok":true,"output":"retired-copy-output"}\\n'
          exit 0
        fi
        printf '{"tools":[]}\\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let generated = adoptedFrom.map {
            #","generated":{"by":"zen","adoptedFrom":"\#($0)"}"#
        } ?? ""
        try """
        {"id":"\(id)","enabled":true,"executable":"feature","tools":[{"name":"\(toolName)","description":"Retired copy","inputSchema":{},"presentation":{"title":"Retired copy","action":"Use","kind":"other","metadata":[],"sections":[]}}]\(generated)}
        """.write(
            to: directoryURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename),
            atomically: true,
            encoding: .utf8
        )
    }

    /// Relative path → contents of every regular file, plus the relative paths
    /// of every directory, below `rootURL`.
    private static func directorySnapshot(_ rootURL: URL) throws -> [String: Data] {
        var snapshot: [String: Data] = [:]
        let rootPath = rootURL.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]
        ) else {
            return snapshot
        }
        while let url = enumerator.nextObject() as? URL {
            let relativePath = String(url.standardizedFileURL.path.dropFirst(rootPath.count))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isRegularFile == true {
                snapshot[relativePath] = try Data(contentsOf: url)
            } else if values.isDirectory == true {
                snapshot[relativePath + "/"] = Data()
            }
        }
        return snapshot
    }
}
