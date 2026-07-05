//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension SwiftFeatureRuntimeTests {
    @Test
    func featureScaffoldCreatesSwift63PackageBuildsAndEnables() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-scaffold-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let scaffoldOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-scaffold",
                name: "feature.scaffold",
                argumentsObject: [
                    "id": "example-feature",
                    "toolName": "example.echo"
                ],
                argumentsJSON: #"{"id":"example-feature","toolName":"example.echo"}"#
            )
        )
        let scaffold = try JSONDecoder().decode(
            SwiftFeatureScaffoldReport.self,
            from: Data(scaffoldOutput.utf8)
        )

        let packageFirstLine = try String(
            contentsOf: URL(fileURLWithPath: scaffold.packagePath),
            encoding: .utf8
        ).components(separatedBy: .newlines).first
        #expect(packageFirstLine == "// swift-tools-version: 6.3")

        let validateOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-validate",
                name: "feature.validate",
                argumentsObject: ["id": "example-feature"],
                argumentsJSON: #"{"id":"example-feature"}"#
            )
        )
        let validation = try JSONDecoder().decode(
            SwiftFeatureValidationReport.self,
            from: Data(validateOutput.utf8)
        )
        #expect(validation.ok)

        let buildOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-build",
                name: "feature.build",
                argumentsObject: ["id": "example-feature"],
                argumentsJSON: #"{"id":"example-feature"}"#
            )
        )
        let build = try JSONDecoder().decode(
            SwiftFeatureBuildReport.self,
            from: Data(buildOutput.utf8)
        )
        #expect(build.ok)
        #expect(FileManager.default.isExecutableFile(atPath: build.executablePath))

        _ = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-enable",
                name: "feature.enable",
                argumentsObject: ["id": "example-feature"],
                argumentsJSON: #"{"id":"example-feature"}"#
            )
        )

        let descriptors = await runtime.descriptors(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        #expect(descriptors.map(\.name).contains("example.echo"))

        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "example-echo",
                name: "example.echo",
                argumentsObject: ["text": "ciao"],
                argumentsJSON: #"{"text":"ciao"}"#
            ),
            workingDirectory: rootURL
        )
        #expect(output == "ciao")
    }

    @Test
    func featureDeleteRemovesGeneratedPackageButRejectsBundledFeatures() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-delete-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        _ = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-scaffold-delete",
                name: "feature.scaffold",
                argumentsObject: [
                    "id": "throwaway-feature",
                    "toolName": "throwaway.run"
                ],
                argumentsJSON: #"{"id":"throwaway-feature","toolName":"throwaway.run"}"#
            )
        )
        let featureURL = rootURL.appendingPathComponent("throwaway-feature", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: featureURL.path))

        let deleteOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-delete",
                name: "feature.delete",
                argumentsObject: ["id": "throwaway-feature"],
                argumentsJSON: #"{"id":"throwaway-feature"}"#
            )
        )
        let deleteReport = try JSONDecoder().decode(
            SwiftFeatureDeleteReport.self,
            from: Data(deleteOutput.utf8)
        )
        #expect(deleteReport.ok)
        #expect(deleteReport.removed)
        #expect(deleteReport.directoryPath == featureURL.path)
        #expect(!FileManager.default.fileExists(atPath: featureURL.path))

        let listOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-list-after-delete",
                name: "feature.list",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )
        #expect(!listOutput.contains("throwaway-feature"))

        do {
            _ = try await runtime.executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "feature-delete-bundled",
                    name: "feature.delete",
                    argumentsObject: ["id": "git-tools"],
                    argumentsJSON: #"{"id":"git-tools"}"#
                )
            )
            Issue.record("feature.delete unexpectedly removed a bundled feature.")
        } catch {
            #expect(error.localizedDescription.contains("cannot be deleted"))
        }
    }

    @Test
    func featureScaffoldCreatesMCPBridgePackage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-mcp-bridge-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let scaffoldOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-scaffold-mcp",
                name: "feature.scaffold",
                argumentsObject: [
                    "id": "linear-mcp",
                    "template": "mcp-bridge",
                    "displayName": "Linear MCP",
                    "serviceName": "Linear",
                    "toolPrefix": "linear.",
                    "endpointURL": "http://127.0.0.1:65535/mcp"
                ],
                argumentsJSON: "{}"
            )
        )
        let scaffold = try JSONDecoder().decode(
            SwiftFeatureScaffoldReport.self,
            from: Data(scaffoldOutput.utf8)
        )

        let packageContents = try String(
            contentsOf: URL(fileURLWithPath: scaffold.packagePath),
            encoding: .utf8
        )
        let sourceContents = try String(
            contentsOf: URL(fileURLWithPath: scaffold.sourcePath),
            encoding: .utf8
        )
        let manifest = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: Data(
                contentsOf: URL(fileURLWithPath: scaffold.manifestPath)
            )
        )

        #expect(packageContents.components(separatedBy: .newlines).first == "// swift-tools-version: 6.3")
        #expect(packageContents.contains(#".product(name: "ZenCODECore", package: "ZenCODE")"#))
        #expect(sourceContents.contains("RemoteMCPToolExecutor"))
        #expect(sourceContents.contains("http://127.0.0.1:65535/mcp"))
        #expect(manifest.discoversToolsAtRuntime)
        #expect(manifest.toolNamePrefixes == ["linear."])
        #expect(manifest.tools.isEmpty)

        let validateOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-validate-mcp",
                name: "feature.validate",
                argumentsObject: ["id": "linear-mcp"],
                argumentsJSON: #"{"id":"linear-mcp"}"#
            )
        )
        let validation = try JSONDecoder().decode(
            SwiftFeatureValidationReport.self,
            from: Data(validateOutput.utf8)
        )
        #expect(validation.ok)

        let buildOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-build-mcp",
                name: "feature.build",
                argumentsObject: [
                    "id": "linear-mcp",
                    "timeoutSeconds": 120
                ],
                argumentsJSON: "{}"
            )
        )
        let build = try JSONDecoder().decode(
            SwiftFeatureBuildReport.self,
            from: Data(buildOutput.utf8)
        )
        #expect(build.ok)
        #expect(FileManager.default.isExecutableFile(atPath: build.executablePath))
    }

    @Test
    func featureScaffoldRejectsPathsOutsideGeneratedFeatureRoot() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-scaffold-root-\(UUID().uuidString)", isDirectory: true)
        let outsideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-scaffold-outside-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: outsideURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])

        do {
            _ = try await runtime.executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "feature-scaffold-outside",
                    name: "feature.scaffold",
                    argumentsObject: [
                        "id": "outside-feature",
                        "toolName": "outside.echo",
                        "path": outsideURL.path
                    ],
                    argumentsJSON: "{}"
                )
            )
            Issue.record("feature.scaffold unexpectedly allowed a path outside the generated feature root.")
        } catch {
            #expect(error.localizedDescription.contains("feature.scaffold can only create packages"))
            #expect(!FileManager.default.fileExists(atPath: outsideURL.path))
        }
    }

    @Test
    func featureInstallCopiesBuildsAndEnablesExternalFeature() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-install-root-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-install-source-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let sourceRuntime = SwiftFeatureRuntime(featureSearchRoots: [sourceURL])
        _ = try await sourceRuntime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-install-scaffold",
                name: "feature.scaffold",
                argumentsObject: [
                    "id": "install-feature",
                    "toolName": "installed.echo"
                ],
                argumentsJSON: "{}"
            )
        )
        let sourceFeatureURL = sourceURL.appendingPathComponent("install-feature", isDirectory: true)

        let installOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-install",
                name: "feature.install",
                argumentsObject: [
                    "path": sourceFeatureURL.path
                ],
                argumentsJSON: "{}"
            )
        )
        let install = try JSONDecoder().decode(
            SwiftFeatureInstallReport.self,
            from: Data(installOutput.utf8)
        )

        #expect(install.ok)
        #expect(install.copied)
        #expect(install.built)
        #expect(install.enabled)
        #expect(install.destinationPath == rootURL.appendingPathComponent("install-feature").path)
        #expect(FileManager.default.fileExists(atPath: install.manifestPath))

        let descriptors = await runtime.descriptors(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        #expect(descriptors.contains { $0.name == "installed.echo" })

        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "feature-install-invoke",
                name: "installed.echo",
                argumentsObject: ["text": "installato"],
                argumentsJSON: #"{"text":"installato"}"#
            ),
            workingDirectory: rootURL
        )
        #expect(output == "installato")
    }

    @Test
    func featureValidateRejectsNonSwift63Package() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-swift-version-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let scaffoldOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-scaffold",
                name: "feature.scaffold",
                argumentsObject: [
                    "id": "wrong-version-feature",
                    "toolName": "wrongversion.echo"
                ],
                argumentsJSON: #"{"id":"wrong-version-feature","toolName":"wrongversion.echo"}"#
            )
        )
        let scaffold = try JSONDecoder().decode(
            SwiftFeatureScaffoldReport.self,
            from: Data(scaffoldOutput.utf8)
        )
        var packageContents = try String(
            contentsOf: URL(fileURLWithPath: scaffold.packagePath),
            encoding: .utf8
        )
        packageContents = packageContents.replacingOccurrences(
            of: "// swift-tools-version: 6.3",
            with: "// swift-tools-version: 6.2"
        )
        try packageContents.write(
            to: URL(fileURLWithPath: scaffold.packagePath),
            atomically: true,
            encoding: .utf8
        )

        let validateOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-validate",
                name: "feature.validate",
                argumentsObject: ["id": "wrong-version-feature"],
                argumentsJSON: #"{"id":"wrong-version-feature"}"#
            )
        )
        let validation = try JSONDecoder().decode(
            SwiftFeatureValidationReport.self,
            from: Data(validateOutput.utf8)
        )

        #expect(!validation.ok)
        #expect(validation.errors.contains { $0.contains("Swift tools 6.3") })
    }

    @Test
    func featureManagementEnablesGeneratedFeatureManifestAndReloads() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-management-\(UUID().uuidString)", isDirectory: true)
        let featureURL = rootURL.appendingPathComponent("generated", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: featureURL,
            withIntermediateDirectories: true
        )
        let executableURL = featureURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        if [ "$1" = "--invoke" ]; then
          cat >/dev/null
          printf '{"ok":true,"output":"generated-output"}\n'
          exit 0
        fi
        printf '{"tools":[{"name":"generated.echo","description":"Generated echo","inputSchema":"{}"}]}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )
        let manifestURL = featureURL.appendingPathComponent(SwiftFeatureRegistry.manifestFilename)
        try """
        {
          "id": "generated-fixture",
          "enabled": false,
          "executable": "feature",
          "tools": [
            {
              "name": "generated.echo",
              "description": "Generated echo",
              "inputSchema": {}
            }
          ]
        }
        """.write(
            to: manifestURL,
            atomically: true,
            encoding: .utf8
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let disabledDescriptors = await runtime.descriptors(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        #expect(!disabledDescriptors.map(\.name).contains("generated.echo"))

        let listOutput = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-list",
                name: "feature.list",
                argumentsObject: [:],
                argumentsJSON: "{}"
            )
        )
        #expect(listOutput.contains(#""id" : "generated-fixture""#))
        #expect(listOutput.contains(#""enabled" : false"#))

        _ = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-enable",
                name: "feature.enable",
                argumentsObject: ["id": "generated-fixture"],
                argumentsJSON: #"{"id":"generated-fixture"}"#
            )
        )

        let enabledRecords = SwiftFeatureRegistry.discoverFeatureRecords(
            searchRoots: [rootURL]
        )
        #expect(enabledRecords.first?.manifestEnabled == true)

        let enabledDescriptors = await runtime.descriptors(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        #expect(enabledDescriptors.map(\.name).contains("generated.echo"))

        let output = try await runtime.executeIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "generated-call",
                name: "generated.echo",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )
        #expect(output == "generated-output")

        _ = try await runtime.executeManagementTool(
            toolCall: DirectAgentToolCall(
                id: "feature-disable",
                name: "feature.disable",
                argumentsObject: ["id": "generated-fixture"],
                argumentsJSON: #"{"id":"generated-fixture"}"#
            )
        )
        let disabledRecords = SwiftFeatureRegistry.discoverFeatureRecords(
            searchRoots: [rootURL]
        )
        #expect(disabledRecords.first?.manifestEnabled == false)
    }

    @Test
    func featureAdoptRejectsCoreBundledFeature() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-adopt-core-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        do {
            _ = try await runtime.executeManagementTool(
                toolCall: featureManagementCall(
                    name: "feature.adopt",
                    arguments: ["id": "search-tools"]
                )
            )
            Issue.record("feature.adopt unexpectedly adopted a core bundled feature.")
        } catch {
            #expect(error.localizedDescription.contains("Core Swift feature 'search-tools'"))
        }
    }

    @Test
    func featureEditAdoptsNonCoreBundledFeatureAndDeleteRestoresBundledRecord() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-edit-adopt-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let editOutput = try await runtime.executeManagementTool(
            toolCall: featureManagementCall(
                name: "feature.edit",
                arguments: ["id": "figma-tools"]
            )
        )
        let edit = try JSONDecoder().decode(
            SwiftFeatureEditReport.self,
            from: Data(editOutput.utf8)
        )

        #expect(edit.ok)
        #expect(edit.adopted)
        #expect(edit.adoptedFrom == "figma-tools")
        #expect(edit.packagePath?.hasSuffix("/figma-tools/Package.swift") == true)
        #expect(edit.sourcePaths.contains { $0.hasSuffix("FigmaToolsFeatureMain.swift") })

        let visibleRecords = SwiftFeatureRuntime.defaultFeatureStatuses(
            searchRoots: [rootURL],
            includeTools: false,
            includeDisabled: true
        )
        let figmaRecords = visibleRecords.filter { $0.id == "figma-tools" }
        #expect(figmaRecords.count == 1)
        #expect(figmaRecords.first?.source == .generated)
        #expect(figmaRecords.first?.adoptedFrom == "figma-tools")
        #expect(figmaRecords.first?.editable == true)

        let manifest = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: edit.manifestPath))
        )
        #expect(manifest.generated?.adoptedFrom == "figma-tools")
        #expect(manifest.discoversToolsAtRuntime)
        #expect(manifest.toolNamePrefixes == ["figma."])

        let deleteOutput = try await runtime.executeManagementTool(
            toolCall: featureManagementCall(
                name: "feature.delete",
                arguments: ["id": "figma-tools"]
            )
        )
        let delete = try JSONDecoder().decode(
            SwiftFeatureDeleteReport.self,
            from: Data(deleteOutput.utf8)
        )
        #expect(delete.ok)
        #expect(!FileManager.default.fileExists(atPath: delete.directoryPath))

        let restoredStatuses = SwiftFeatureRuntime.defaultFeatureStatuses(
            searchRoots: [rootURL],
            includeTools: false,
            includeDisabled: true
        )
        let restoredFigma = restoredStatuses.first { $0.id == "figma-tools" }
        #expect(restoredFigma?.source == .bundled)
        #expect(restoredFigma?.adoptable == true)
        #expect(restoredFigma?.editable == false)
    }

    @Test
    func featureEditGeneratedFeatureReturnsEditableContextWithoutAdoption() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-edit-generated-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        _ = try await runtime.executeManagementTool(
            toolCall: featureManagementCall(
                name: "feature.scaffold",
                arguments: [
                    "id": "editable-feature",
                    "toolName": "editable.echo"
                ]
            )
        )

        let editOutput = try await runtime.executeManagementTool(
            toolCall: featureManagementCall(
                name: "feature.edit",
                arguments: ["id": "editable-feature"]
            )
        )
        let edit = try JSONDecoder().decode(
            SwiftFeatureEditReport.self,
            from: Data(editOutput.utf8)
        )

        #expect(edit.ok)
        #expect(!edit.adopted)
        #expect(edit.adopt == nil)
        #expect(edit.directoryPath == rootURL.appendingPathComponent("editable-feature").path)
        #expect(edit.packagePath?.hasSuffix("/editable-feature/Package.swift") == true)
        #expect(edit.sourcePaths.contains { $0.hasSuffix("/Sources/EditableFeature/main.swift") })
        #expect(edit.instructions.contains { $0.contains("feature.validate") })
    }

    private func featureManagementCall(
        name: String,
        arguments: [String: Any]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "\(name)-\(UUID().uuidString)",
            name: name,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
    }
}
