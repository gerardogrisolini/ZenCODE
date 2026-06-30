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
    func directToolExecutorRoutesMatchingToolToSwiftFeature() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-routing-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-dynamic-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "dynamic-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "dynamic.fixture",
                            description: "Runs a dynamic fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ]
                )
            ]
        )
        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "feature-call-1",
            name: "dynamic.fixture",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        let result = await executor.execute(
            sessionID: "test-session",
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["dynamic.fixture"]
        )

        #expect(result.output == "feature-dynamic-output")
    }

    @Test
    func directToolExecutorAllowsFeaturePackageToolsWithFeatureGroupToken() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-generated-token-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"generated-token-output"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "generated-token-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "generated.token",
                            description: "Generated token fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ],
                    source: .generated
                ),
                SwiftFeatureBundle(
                    id: "bundled-token-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "bundled.token",
                            description: "Bundled token fixture",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ],
                    source: .bundled
                )
            ]
        )
        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )

        let descriptors = await executor.descriptors(
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        #expect(descriptors.map(\.name).contains("generated.token"))
        #expect(descriptors.map(\.name).contains("bundled.token"))

        let generatedResult = await executor.execute(
            sessionID: "test-session",
            toolCall: DirectAgentToolCall(
                id: "generated-token-call",
                name: "generated.token",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL,
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )
        let bundledResult = await executor.execute(
            sessionID: "test-session",
            toolCall: DirectAgentToolCall(
                id: "bundled-token-call",
                name: "bundled.token",
                argumentsObject: [:],
                argumentsJSON: "{}"
            ),
            workingDirectory: rootURL,
            allowedToolNames: [SwiftFeatureRuntime.featurePackageToolsAllowedName]
        )

        #expect(generatedResult.output == "generated-token-output")
        #expect(bundledResult.output == "generated-token-output")
    }

    @Test
    func directToolExecutorDoesNotFallbackToExtractedSearchTools() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-no-fallback-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "no-fallback-call-1",
            name: "search.glob",
            argumentsObject: [
                "pattern": "*.swift"
            ],
            argumentsJSON: #"{"pattern":"*.swift"}"#
        )

        let result = await executor.execute(
            sessionID: "test-session",
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["search.glob"]
        )

        #expect(result.output == "Tool error: Unknown tool: search.glob")
    }

    @Test
    func directToolExecutorKeepsFileAndTextToolsInCoreRuntime() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-core-local-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let fileURL = rootURL.appendingPathComponent("sample.txt")
        try "ciao mondo\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )

        let readResult = await executor.execute(
            sessionID: "test-session",
            toolCall: DirectAgentToolCall(
                id: "core-local-call-1",
                name: "local.readFile",
                argumentsObject: ["path": "sample.txt"],
                argumentsJSON: #"{"path":"sample.txt"}"#
            ),
            workingDirectory: rootURL,
            allowedToolNames: ["local.readFile"]
        )
        let wcResult = await executor.execute(
            sessionID: "test-session",
            toolCall: DirectAgentToolCall(
                id: "core-local-call-2",
                name: "text.wc",
                argumentsObject: ["path": "sample.txt"],
                argumentsJSON: #"{"path":"sample.txt"}"#
            ),
            workingDirectory: rootURL,
            allowedToolNames: ["text.wc"]
        )

        #expect(readResult.output.contains("1\tciao mondo"))
        #expect(wcResult.output.contains("words: 2"))
    }

    @Test
    func directToolExecutorKeepsLocalExecInCoreRuntime() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-local-exec-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-local-exec"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "local-exec-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "local.exec",
                            description: "Should not replace core local exec",
                            inputSchema: #"{"type":"object","properties":{}}"#
                        )
                    ]
                )
            ]
        )
        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "local-exec-call-1",
            name: "local.exec",
            argumentsObject: [
                "command": "printf core-local-exec"
            ],
            argumentsJSON: #"{"command":"printf core-local-exec"}"#
        )

        let result = await executor.execute(
            sessionID: "test-session",
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["local.exec"]
        )

        #expect(result.output.contains("stdout:\ncore-local-exec"))
        #expect(!result.output.contains("feature-local-exec"))
    }

    @Test
    func directToolExecutorDoesNotAuthorizeDynamicGitToolsBeforeFeatureExecution() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-feature-git-auth-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let executableURL = rootURL.appendingPathComponent("feature")
        try """
        #!/bin/sh
        cat >/dev/null
        printf '{"ok":true,"output":"feature-git-commit"}\n'
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let runtime = SwiftFeatureRuntime(
            features: [
                SwiftFeatureBundle(
                    id: "git-fixture",
                    executableURL: executableURL,
                    tools: [
                        ToolDescriptor(
                            name: "git.commit",
                            description: "Should execute through the feature runtime",
                            inputSchema: #"{"type":"object","properties":{"message":{"type":"string"}},"required":["message"]}"#
                        )
                    ]
                )
            ]
        )
        let executor = DirectToolExecutor(
            outputLimit: 24_000,
            authorizationHandler: { request in
                Issue.record("Unexpected authorization request: \(request.toolName) / \(request.kind)")
                return false
            },
            swiftFeatureRuntime: runtime,
            subAgentBackendFactory: { SwiftFeatureTestAgentRuntimeBackend() }
        )
        let toolCall = DirectAgentToolCall(
            id: "git-commit-call-1",
            name: "git.commit",
            argumentsObject: [
                "message": "test"
            ],
            argumentsJSON: #"{"message":"test"}"#
        )

        let result = await executor.execute(
            sessionID: "test-session",
            toolCall: toolCall,
            workingDirectory: rootURL,
            allowedToolNames: ["git.commit"]
        )

        #expect(result.output.contains("feature-git-commit"))
        #expect(!result.output.contains("Git command cancelled."))
    }
}
