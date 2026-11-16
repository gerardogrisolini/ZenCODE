//
//  SwiftFeatureRuntimeTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing
import ToolCore

extension SwiftFeatureRuntimeTests {
    @Test
    func featureListRenderingPreservesSlashAndUnicodeBytes() async throws {
        let runtime = SwiftFeatureRuntime(
            features: [SwiftFeatureBundle(
                id: "caffè/工具",
                executableURL: URL(fileURLWithPath: "/fixture/caffe/工具"),
                tools: [],
                toolNamePrefixes: ["caffè/"],
                toolNameAliases: ["工具/eco"]
            )]
        )
        let expected = """
        {
          "features" : [
            {
              "adoptable" : false,
              "available" : false,
              "discoversToolsAtRuntime" : false,
              "editable" : true,
              "enabled" : true,
              "executablePath" : "/fixture/caffe/工具",
              "id" : "caffè/工具",
              "isCore" : false,
              "source" : "generated",
              "toolCount" : 0,
              "toolNameAliases" : [
                "工具/eco"
              ],
              "toolNamePrefixes" : [
                "caffè/"
              ],
              "tools" : [

              ]
            }
          ]
        }
        """
        for prefix in [nil, "Feature aggiornata / caffè ☕"] as [String?] {
            let output = try await runtime.renderFeatureList(
                prefix: prefix,
                includeTools: true,
                includeDisabled: true,
                discoverRuntimeTools: false
            )
            let expectedOutput = prefix.map { "\($0)\n\(expected)" } ?? expected
            #expect(Array(output.utf8) == Array(expectedOutput.utf8))
        }
    }

    @Test
    func featureUpdateCompatibilityAliasSharesTheCanonicalDescriptor() throws {
        let edit = try #require(
            SwiftFeatureRuntime.managementToolDescriptors.first { $0.name == "feature.edit" }
        )
        let update = try #require(
            SwiftFeatureRuntime.managementToolDescriptors.first { $0.name == "feature.update" }
        )
        #expect(update.inputSchema == edit.inputSchema)
        #expect(update.description == edit.description)
    }

    @Test
    func featureScaffoldCreatesSwift64PackageBuildsAndEnables() async throws {
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

        let packageContents = try String(
            contentsOf: URL(fileURLWithPath: scaffold.packagePath),
            encoding: .utf8
        )
        let sourceContents = try String(
            contentsOf: URL(fileURLWithPath: scaffold.sourcePath),
            encoding: .utf8
        )
        #expect(packageContents.components(separatedBy: .newlines).first == "// swift-tools-version: 6.4")
        #expect(packageContents.contains(#".product(name: "FeatureKit", package: "ZenCODE")"#))
        #expect(packageContents.contains(#".product(name: "ToolCore", package: "ZenCODE")"#))
        #expect(sourceContents.contains("GeneratedEchoTool: FeatureTool"))
        #expect(sourceContents.contains("static let presentation = ToolPresentationDefinition("))
        #expect(sourceContents.contains("FeatureRunner.run"))
        #expect(!sourceContents.contains("strategy"))

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
        let scaffoldedDescriptor = try #require(
            descriptors.first { $0.name == "example.echo" }
        )
        let presentation = try #require(scaffoldedDescriptor.presentation)
        #expect(presentation.title == "Echo")
        #expect(presentation.target?.keyPaths == ["text"])

        let output = try await runtime.executeResultIfAvailable(
            toolCall: DirectAgentToolCall(
                id: "example-echo",
                name: "example.echo",
                argumentsObject: ["text": "ciao"],
                argumentsJSON: #"{"text":"ciao"}"#
            ),
            workingDirectory: rootURL
        )?.output
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

    #if os(macOS)
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

        #expect(packageContents.components(separatedBy: .newlines).first == "// swift-tools-version: 6.4")
        #expect(!packageContents.contains(#".product(name: "ZenCODECore", package: "ZenCODE")"#))
        #expect(packageContents.contains(#".product(name: "FeatureMCPBridgeKit", package: "ZenCODE")"#))
        #expect(sourceContents.contains("RemoteMCPToolExecutor"))
        #expect(sourceContents.contains("let presentation = ToolPresentationDefinition("))
        #expect(sourceContents.contains("presentation: presentation"))
        #expect(sourceContents.contains("http://127.0.0.1:65535/mcp"))
        #expect(sourceContents.contains("environment: ProcessInfo.processInfo.environment"))
        #expect(!sourceContents.contains("bridgeEnvironment"))
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
                    "id": "linear-mcp"
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
    #endif

    @Test
    func featureScaffoldRejectsMCPSecretsBeforeInstallingPackage() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-mcp-secrets-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let runtime = SwiftFeatureRuntime(featureSearchRoots: [rootURL])
        let cases: [(id: String, arguments: [String: Any], expectedError: String)] = [
            (
                id: "secret-environment-mcp",
                arguments: [
                    "id": "secret-environment-mcp",
                    "template": "mcp-bridge",
                    "toolPrefix": "secret_environment.",
                    "executablePath": "/usr/bin/false",
                    "environment": ["TOKEN": "super-secret"]
                ],
                expectedError: "do not accept static environment values"
            ),
            (
                id: "secret-endpoint-mcp",
                arguments: [
                    "id": "secret-endpoint-mcp",
                    "template": "mcp-bridge",
                    "toolPrefix": "secret_endpoint.",
                    "endpointURL": "https://mcp.example.com/tools?client_secret=super-secret"
                ],
                expectedError: "cannot contain credentials"
            ),
            (
                id: "secret-environment-alias-mcp",
                arguments: [
                    "id": "secret-environment-alias-mcp",
                    "template": "mcp-bridge",
                    "toolPrefix": "secret_environment_alias.",
                    "executablePath": "/usr/bin/false",
                    "environment": [String: String](),
                    "env": ["API_KEY": "super-secret"]
                ],
                expectedError: "do not accept static environment values"
            )
        ]

        for testCase in cases {
            do {
                _ = try await runtime.executeManagementTool(
                    toolCall: DirectAgentToolCall(
                        id: "feature-scaffold-\(testCase.id)",
                        name: "feature.scaffold",
                        argumentsObject: testCase.arguments,
                        argumentsJSON: "{}"
                    )
                )
                Issue.record("Expected feature.scaffold to reject secret configuration.")
            } catch {
                #expect(error.localizedDescription.contains(testCase.expectedError))
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: rootURL.appendingPathComponent(testCase.id).path
                )
            )
        }
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
}
