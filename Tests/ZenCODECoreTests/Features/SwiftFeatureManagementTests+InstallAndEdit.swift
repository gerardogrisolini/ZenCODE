//
//  SwiftFeatureManagementTests+InstallAndEdit.swift
//  ZenCODE
//
//  Runtime tests for installing, validating, enabling, and editing Swift
//  features through the management tools, with the call helper they share.
//

import Foundation
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

extension SwiftFeatureRuntimeTests {
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

        let output = try await runtime.executeResultIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "feature-install-invoke",
                name: "installed.echo",
                argumentsObject: ["text": "installato"],
                argumentsJSON: #"{"text":"installato"}"#
            ),
            workingDirectory: rootURL
        )?.output
        #expect(output == "installato")
    }

    @Test
    func featureValidateRejectsNonSwift64Package() async throws {
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
            of: "// swift-tools-version: 6.4",
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
        #expect(validation.errors.contains { $0.contains("Swift tools 6.4") })
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
        printf '{"tools":[{"name":"generated.echo","description":"Generated echo","inputSchema":"{}","presentation":{"title":"Dynamic tool","action":"Use","kind":"other","metadata":[],"sections":[]}}]}\n'
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
              "inputSchema": {},
              "presentation": {
                "title": "Generated echo",
                "action": "Use",
                "kind": "other",
                "metadata": [],
                "sections": []
              }
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

        let output = try await runtime.executeResultIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "generated-call",
                name: "generated.echo",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL
        )?.output
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
    func featureEditCreatesLocalCopyForBundledFeatureAndDeleteRestoresBundledRecord() async throws {
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
