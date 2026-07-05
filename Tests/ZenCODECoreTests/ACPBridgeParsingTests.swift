//
//  ACPCompatibilityTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/06/26.
//

import Foundation
@testable import FeatureMCPBridgeKit
@testable import ZenCODECore
import Testing

extension ACPCompatibilityTests {
    @Test
    func sessionIDAcceptsACPAndSnakeCaseKeys() {
        #expect(ZenCODEACPBridge.sessionID(from: ["sessionId": "abc"]) == "abc")
        #expect(ZenCODEACPBridge.sessionID(from: ["session_id": "def"]) == "def")
        #expect(ZenCODEACPBridge.sessionID(from: ["id": "ghi"]) == "ghi")
        #expect(ZenCODEACPBridge.sessionID(from: ["sessionId": "   "]) == nil)
    }

    @Test
    func allowedToolsAcceptACPAliasesAndSelectionNames() {
        let allowedTools = ZenCODEACPBridge.allowedToolNames(from: [
            "allowed_tools": ["xcode", "shell"] as [String]
        ])

        #expect(allowedTools?.contains("xcode.") == true)
        #expect(allowedTools?.contains("local.exec") == true)
    }

    @Test
    func allowedToolsAcceptDescriptorObjects() {
        let allowedTools = ZenCODEACPBridge.allowedToolNames(from: [
            "tools": [
                ["name": "xcode.BuildProject"],
                ["toolName": "git.status"]
            ] as [[String: Any]]
        ])

        #expect(allowedTools == ["git.status", "xcode.BuildProject"])
    }

    @Test
    func acpVerboseLogFileWritesToSupportLogsDirectory() async throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-acp-log-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }

        let logFile = try #require(
            ACPVerboseLogFile.open(supportDirectoryURL: supportURL)
        )
        await logFile.write("sample diagnostic")

        let contents = try String(contentsOf: logFile.url, encoding: .utf8)

        #expect(logFile.url.deletingLastPathComponent().lastPathComponent == "logs")
        #expect(logFile.url.lastPathComponent.hasPrefix("acp-"))
        #expect(contents.contains("sample diagnostic"))
    }

    @Test
    func mcpServersParseACPStdioXcodeConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Xcode",
                    "command": "/usr/bin/xcrun",
                    "args": ["mcpbridge"],
                    "env": [
                        [
                            "name": "MCP_XCODE_SESSION_ID",
                            "value": "session-1"
                        ]
                    ]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Xcode")
        #expect(definition.type == "stdio")
        #expect(definition.isXcodeCandidate)
        #expect(definition.configuration.executablePath == "/usr/bin/xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(definition.configuration.environment["MCP_XCODE_SESSION_ID"] == "session-1")
        #expect(definition.configuration.usesMCPBridgeExecutable)
    }

    @Test
    func mcpServersParseBareXcrunXcodeConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "xcode-tools",
                    "command": "xcrun",
                    "args": ["mcpbridge"]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "xcode-tools")
        #expect(definition.isXcodeCandidate)
        #expect(definition.configuration.executablePath == "xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(definition.configuration.usesMCPBridgeExecutable)
    }

    @Test
    func mcpServersParseACPHTTPConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcp_servers": [
                [
                    "type": "http",
                    "name": "Docs",
                    "url": "https://mcp.example.test/mcp",
                    "headers": [
                        [
                            "name": "Authorization",
                            "value": "Bearer token"
                        ]
                    ]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Docs")
        #expect(definition.type == "http")
        #expect(!definition.isXcodeCandidate)
        #expect(definition.configuration.endpointURL?.absoluteString == "https://mcp.example.test/mcp")
        #expect(definition.configuration.httpHeaders["Authorization"] == "Bearer token")
    }

    @Test
    func mcpServersParseMapConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                "Xcode": [
                    "type": "stdio",
                    "command": "/usr/bin/xcrun",
                    "args": ["mcpbridge"]
                ] as [String: Any]
            ] as [String: Any]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Xcode")
        #expect(definition.configuration.executablePath == "/usr/bin/xcrun")
        #expect(definition.configuration.arguments == ["mcpbridge"])
        #expect(ZenCODEACPBridge.mcpServerInputSummary(from: [
            "mcpServers": [
                "Xcode": [:] as [String: Any]
            ] as [String: Any]
        ]) == "object(1:Xcode)")
    }

    #if os(macOS)
    @Test
    func localMCPTransportResolvesBareExecutableNamesAndKeepsPATH() throws {
        let configuration = MCPServerConfiguration(
            executablePath: "env",
            arguments: [],
            environment: [
                "MCP_XCODE_SESSION_ID": "session-1",
                "PATH": "/custom/bin"
            ]
        )
        let expectedExecutableURL = try #require(DeveloperToolEnvironment.executableURL(named: "env"))
        let resolvedEnvironment = FeatureMCPBridgeKit.MCPClient.resolvedEnvironment(for: configuration)
        let resolvedPathParts = Set((resolvedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init))

        #expect(FeatureMCPBridgeKit.MCPClient.resolvedExecutableURL(for: configuration).path == expectedExecutableURL.path)
        #expect(resolvedEnvironment["MCP_XCODE_SESSION_ID"] == "session-1")
        #expect(resolvedPathParts.contains("/custom/bin"))
        #expect(resolvedPathParts.contains("/usr/bin"))
    }
    #endif

    @Test
    func allowedToolNamesIncludeACPProvidedMCPDescriptors() {
        let allowedTools = ZenCODEACPBridge.allowedToolNames(
            ["local.exec"],
            adding: [
                DirectToolDescriptor(
                    name: "xcode.BuildProject",
                    description: "Xcode: Build",
                    inputSchema: "{}"
                )
            ]
        )

        #expect(allowedTools == ["local.exec", "xcode.BuildProject"])
    }
}
