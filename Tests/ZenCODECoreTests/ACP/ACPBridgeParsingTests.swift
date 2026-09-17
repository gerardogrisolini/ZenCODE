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
import ToolCore

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
    func mcpServersParseACPStdioConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "Fixture",
                    "command": "/usr/bin/env",
                    "args": ["fixture-server"],
                    "env": [
                        [
                            "name": "MCP_SESSION_ID",
                            "value": "session-1"
                        ]
                    ]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Fixture")
        #expect(definition.type == "stdio")
        #expect(definition.configuration.executablePath == "/usr/bin/env")
        #expect(definition.configuration.arguments == ["fixture-server"])
        #expect(definition.configuration.environment["MCP_SESSION_ID"] == "session-1")
    }

    @Test
    func mcpServersParseBareExecutableConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                [
                    "type": "stdio",
                    "name": "fixture-tools",
                    "command": "fixture-server",
                    "args": ["serve"]
                ] as [String: Any]
            ]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "fixture-tools")
        #expect(definition.configuration.executablePath == "fixture-server")
        #expect(definition.configuration.arguments == ["serve"])
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
        #expect(definition.configuration.endpointURL?.absoluteString == "https://mcp.example.test/mcp")
        #expect(definition.configuration.httpHeaders["Authorization"] == "Bearer token")
    }

    @Test
    func mcpServersParseMapConfiguration() throws {
        let definitions = ZenCODEACPBridge.mcpServerDefinitions(from: [
            "mcpServers": [
                "Fixture": [
                    "type": "stdio",
                    "command": "/usr/bin/env",
                    "args": ["fixture-server"]
                ] as [String: Any]
            ] as [String: Any]
        ])

        let definition = try #require(definitions.first)

        #expect(definitions.count == 1)
        #expect(definition.name == "Fixture")
        #expect(definition.configuration.executablePath == "/usr/bin/env")
        #expect(definition.configuration.arguments == ["fixture-server"])
    }

    @Test
    func mcpServerStringMapsAcceptTypedSwiftShapes() throws {
        let cases: [(name: String, value: Any, expected: [String: String])] = [
            (
                "string map",
                [" HEADER ": " value "] as [String: String],
                [" HEADER ": " value "]
            ),
            (
                "any map",
                ["KEEP": " value ", "DROP": 1] as [String: Any],
                ["KEEP": " value "]
            ),
            (
                "typed entries",
                [
                    ["name": " name ", "key": "ignored", "value": " value "],
                    ["name": "  ", "key": " key ", "value": "from-key"],
                    ["name": "  ", "key": "\t", "value": "discard"],
                    ["name": "missing"],
                    ["name": "duplicate", "value": "first"],
                    ["key": " duplicate ", "value": "last"],
                ] as [[String: String]],
                ["name": " value ", "key": "from-key", "missing": "", "duplicate": "last"]
            ),
            (
                "any entries",
                [
                    ["name": " name ", "key": "ignored", "value": " value "],
                    ["name": "  ", "key": " key ", "value": "from-key"],
                    ["name": "missing"],
                    ["name": "non-string", "value": 1],
                    ["name": 1, "key": 2, "value": "discard"],
                    ["name": "duplicate", "value": "first"],
                    ["key": " duplicate ", "value": "last"],
                ] as [[String: Any]],
                [
                    "name": " value ", "key": "from-key", "missing": "",
                    "non-string": "", "duplicate": "last",
                ]
            ),
            (
                "heterogeneous entries",
                [
                    ["name": " name ", "key": "ignored", "value": " value "] as [String: Any],
                    ["name": "  ", "key": " key ", "value": "from-key"] as [String: Any],
                    ["name": "missing"] as [String: Any],
                    ["name": "non-string", "value": 1] as [String: Any],
                    ["name": 1, "key": 2, "value": "discard"] as [String: Any],
                    "malformed",
                    ["name": "duplicate", "value": "first"] as [String: Any],
                    ["key": " duplicate ", "value": "last"] as [String: Any],
                ] as [Any],
                [
                    "name": " value ", "key": "from-key", "missing": "",
                    "non-string": "", "duplicate": "last",
                ]
            ),
        ]

        for fixture in cases {
            let definition = try #require(ZenCODEACPBridge.mcpServerDefinitions(from: [
                "mcpServers": [[
                    "name": fixture.name,
                    "command": "/usr/bin/env",
                    "env": fixture.value,
                ] as [String: Any]],
            ]).first)

            #expect(definition.configuration.environment == fixture.expected)
        }
    }

    @Test
    func mcpServerStringMapsRespectAliasesAndDecodedInput() throws {
        let aliases: [(value: Any, expected: [String: String])] = [
            ([:] as [String: String], [:]),
            (["DROP": 1] as [String: Any], [:]),
            (42, ["FALLBACK": "used"]),
        ]
        for fixture in aliases {
            let definition = try #require(ZenCODEACPBridge.mcpServerDefinitions(from: [
                "mcpServers": [[
                    "command": "/usr/bin/env",
                    "env": fixture.value,
                    "environment": ["FALLBACK": "used"] as [String: String],
                ] as [String: Any]],
            ]).first)

            #expect(definition.configuration.environment == fixture.expected)
        }

        let decoded = try #require(JSONSerialization.jsonObject(with: Data(#"""
        {"mcpServers":[{"type":"http","name":"Decoded","url":"https://mcp.example.test","headers":[
            {"name":" Authorization ","value":"Bearer one"},
            {"name":"Authorization","value":"Bearer two"},
            {"key":" X-Empty "},
            {"name":"  ","key":"\t"},
            {"name":42,"value":"discard"}
        ]}]}
        """#.utf8)) as? [String: Any])
        let definition = try #require(ZenCODEACPBridge.mcpServerDefinitions(from: decoded).first)

        #expect(definition.configuration.httpHeaders == [
            "Authorization": "Bearer two",
            "X-Empty": "",
        ])
    }

    #if os(macOS)
    @Test
    func localMCPTransportResolvesBareExecutableNamesAndKeepsPATH() throws {
        let configuration = MCPServerConfiguration(
            executablePath: "env",
            arguments: [],
            environment: [
                "MCP_SESSION_ID": "session-1",
                "PATH": "/custom/bin"
            ]
        )
        let expectedExecutableURL = try #require(DeveloperToolEnvironment.executableURL(named: "env"))
        let resolvedEnvironment = FeatureMCPBridgeKit.MCPClient.resolvedEnvironment(for: configuration)
        let resolvedPathParts = Set((resolvedEnvironment["PATH"] ?? "").split(separator: ":").map(String.init))

        #expect(FeatureMCPBridgeKit.MCPClient.resolvedExecutableURL(for: configuration).path == expectedExecutableURL.path)
        #expect(resolvedEnvironment["MCP_SESSION_ID"] == "session-1")
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
                    description: "Fixture: Build",
                    inputSchema: "{}"
                )
            ]
        )

        #expect(allowedTools == ["local.exec", "xcode.BuildProject"])
    }
}
