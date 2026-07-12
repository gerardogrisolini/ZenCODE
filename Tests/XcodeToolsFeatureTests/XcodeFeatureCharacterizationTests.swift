//
//  XcodeFeatureCharacterizationTests.swift
//  ZenCODE
//

import Foundation
import FeatureKit
@testable import FeatureMCPBridgeKit
@testable import XcodeToolsFeature
import ToolCore
import Testing

@Suite(.serialized)
struct XcodeFeatureCharacterizationTests {
    @Test
    func xcodeEnvironmentConfigurationPreservesExplicitBridgeArgumentsAndSession() throws {
        let configuration = try #require(
            XcodeMCPServerConfiguration.configuration(fromEnvironment: [
                "XCODE_MCP_EXECUTABLE": " /tmp/mcpbridge ",
                "XCODE_MCP_ARGUMENTS": "--session\nexample\n",
                "MCP_XCODE_PID": " 123 ",
                "MCP_XCODE_SESSION_ID": " session-1 " 
            ])
        )

        #expect(configuration.executablePath == "/tmp/mcpbridge")
        #expect(configuration.arguments == ["--session", "example"])
        #expect(configuration.environment == [
            "MCP_XCODE_PID": "123",
            "MCP_XCODE_SESSION_ID": "session-1"
        ])
        #expect(configuration.preferredProtocolVersion == "2024-11-05")
    }

    @Test
    func recognizesDirectAndXcrunMCPBridgeConfigurations() {
        let direct = MCPServerConfiguration(
            executablePath: "/Applications/Xcode.app/Contents/Developer/usr/bin/mcpbridge",
            arguments: [],
            environment: [:]
        )
        let xcrun = MCPServerConfiguration(
            executablePath: "/usr/bin/xcrun",
            arguments: ["mcpbridge"],
            environment: [:]
        )
        let unrelated = MCPServerConfiguration(
            executablePath: "/usr/bin/xcrun",
            arguments: ["simctl", "mcpbridge"],
            environment: [:]
        )

        #expect(XcodeMCPServerConfiguration.isBridgeConfiguration(direct))
        #expect(XcodeMCPServerConfiguration.isBridgeConfiguration(xcrun))
        #expect(!XcodeMCPServerConfiguration.isBridgeConfiguration(unrelated))
    }

    #if os(macOS)
    @Test
    func mcpBridgeUsesOptimisticInitializedHandshake() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcode-mcp-handshake-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let requestsURL = rootURL.appendingPathComponent("requests.jsonl")
        let executableURL = rootURL.appendingPathComponent("mcpbridge")
        try """
        #!/bin/sh
        while IFS= read -r line; do
          printf '%s\\n' "$line" >> "\(requestsURL.path)"
          case "$line" in
            *initialized*)
              printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"fixture","version":"1"}}}'
              ;;
          esac
        done
        """.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executableURL.path
        )

        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: executableURL.path,
                arguments: [],
                environment: [:]
            ),
            localTransportPolicy: XcodeMCPTransportPolicy.make()
        )
        do {
            try await client.connect()
            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }

        let requests = try String(contentsOf: requestsURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let methods = try requests.map { request -> String in
            let data = try #require(request.data(using: .utf8))
            let object = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            return try #require(object["method"] as? String)
        }
        #expect(methods == ["initialize", "notifications/initialized"])
    }

    @Test
    func xcodeConsentDiagnosticsMapToPermissionError() async {
        let client = MCPClient(
            configuration: MCPServerConfiguration(
                executablePath: "/usr/bin/xcrun",
                arguments: ["mcpbridge"],
                environment: [:]
            ),
            localTransportPolicy: XcodeMCPTransportPolicy.make()
        )

        let error = await client.classifiedPolicyError(
            kind: .stderr,
            message: "The operation couldn’t be completed. (com.apple.dt.Xcode.MCPBridge.Authorization error 1.)",
            hasStderrOutput: true
        )

        #expect(error?.localizedDescription == XcodeMCPServerConfiguration.authorizationMessage)
    }
    #endif

    @Test
    func workspaceAndRequestCompatibilityContractsRemainStable() throws {
        let windows: JSONValue = .object([
            "structuredContent": .object([
                "windows": .array([
                    .object([
                        "workspacePath": .string("/tmp/Inactive.xcodeproj"),
                        "tabIdentifier": .string("inactive"),
                        "isActive": .bool(false)
                    ]),
                    .object([
                        "workspacePath": .string("file:///tmp/Active.xcworkspace"),
                        "tabIdentifier": .string("active"),
                        "isActive": .bool(true)
                    ])
                ])
            ])
        ])
        let contexts = XcodeWorkspaceContext.contexts(fromListWindowsResult: windows)
        let normalized = try #require(
            XcodeToolRequestCompatibility.normalize(ToolRequest(
                name: "xcode.update",
                arguments: [
                    "path": .string("Sources/App.swift"),
                    "old_string": .string("let answer = 1"),
                    "new_string": .string("let answer = 2"),
                    "tab_id": .string("active")
                ]
            ))
        )

        #expect(contexts.map(\.workspacePath) == ["/tmp", "/tmp"])
        #expect(contexts.map(\.defaultTabIdentifier) == ["active", "inactive"])
        #expect(normalized.name == "XcodeUpdate")
        #expect(normalized.arguments["filePath"]?.stringValue == "Sources/App.swift")
        #expect(normalized.arguments["tabIdentifier"]?.stringValue == "active")
        #expect(normalized.arguments["oldString"]?.stringValue == "let answer = 1")
    }

    @Test
    func featureProcessWireRetainsListAndInvokeJSONContracts() throws {
        guard case let .invoke(toolName, workingDirectory) = FeatureProcessProtocol.parse(arguments: [
            "--invoke", "xcode.XcodeRead", "--working-directory", "/tmp/Workspace"
        ]) else {
            Issue.record("Expected an invoke feature command.")
            return
        }
        #expect(toolName == "xcode.XcodeRead")
        #expect(workingDirectory?.path == "/tmp/Workspace")

        let listData = try FeatureProcessProtocol.renderJSON(FeatureListToolsResponse(
            tools: [FeatureToolDescriptor(
                name: "xcode.XcodeRead",
                description: "Xcode: Reads a file",
                inputSchema: "{}"
            )]
        ))
        let invokeData = try FeatureProcessProtocol.renderJSON(
            FeatureInvocationResponse<String>(output: "ok")
        )
        let list = try #require(
            JSONSerialization.jsonObject(with: listData) as? [String: Any]
        )
        let invoke = try #require(
            JSONSerialization.jsonObject(with: invokeData) as? [String: Any]
        )
        let tools = try #require(list["tools"] as? [[String: Any]])

        #expect(try #require(tools.first?["name"] as? String) == "xcode.XcodeRead")
        #expect(try #require(invoke["ok"] as? Bool))
        #expect(try #require(invoke["output"] as? String) == "ok")
        #expect(invoke["error"] == nil)
    }

    @Test
    func xcodeUpdateIndentationRetryUsesClosestEquivalentMatchOnce() throws {
        let original = ToolRequest(
            name: "XcodeUpdate",
            arguments: [
                "oldString": .string("let answer = 1"),
                "newString": .string("let answer = 2")
            ]
        )
        let failure: JSONValue = .object([
            "success": .bool(false),
            "editsApplied": .number(0),
            "message": .string("No exact edit match. Closest match found:\n    let answer = 1")
        ])

        let retry = retriedXcodeUpdateRequestForIndentationMismatch(
            originalRequest: original,
            failureResult: failure
        )

        #expect(retry?.name == "XcodeUpdate")
        #expect(retry?.arguments["oldString"]?.stringValue == "    let answer = 1")
        #expect(retry?.arguments["newString"]?.stringValue == "    let answer = 2")
    }
}
