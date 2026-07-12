import FeatureMCPBridgeKit
import Foundation
import ToolCore
@testable import XcodeToolsFeature
import Testing

@Suite
struct XcodeToolIntegrationTests {
    @Test
    func recognizesACPServerCandidatesFromNameBridgeCommandAndEnvironment() {
        let xcrunBridge = MCPServerConfiguration(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--toolchain", "default", "mcpbridge"],
            environment: [:]
        )
        let environmentBridge = MCPServerConfiguration(
            executablePath: "/usr/bin/custom-mcp",
            arguments: [],
            environment: ["MCP_XCODE_SESSION_ID": "session-1"]
        )
        let namedHTTP = MCPServerConfiguration(
            executablePath: "",
            arguments: [],
            environment: [:],
            endpointURL: URL(string: "https://mcp.example.test/mcp")
        )

        #expect(XcodeToolIntegration.isServerCandidate(name: "tools", configuration: xcrunBridge))
        #expect(XcodeToolIntegration.isServerCandidate(name: "tools", configuration: environmentBridge))
        #expect(XcodeToolIntegration.isServerCandidate(name: "Xcode MCP", configuration: namedHTTP))
        #expect(!XcodeToolIntegration.isBridgeConfiguration(xcrunBridge))
    }

    @Test
    func canonicalizesPublicAliasesWithoutSendingPrefixToMCP() throws {
        let request = try #require(XcodeToolIntegration.normalizedRequest(
            ToolRequest(
                name: "xcode.XcodeRead",
                arguments: ["path": .string("Sources/App.swift")]
            )
        ))

        #expect(XcodeToolIntegration.canonicalToolName(for: "XcodeRead") == "XcodeRead")
        #expect(XcodeToolIntegration.canonicalToolName(for: "xcode.read") == "XcodeRead")
        #expect(XcodeToolIntegration.canonicalToolName(for: "xcode.XcodeRead") == "XcodeRead")
        #expect(request.name == "XcodeRead")
        #expect(request.arguments["filePath"]?.stringValue == "Sources/App.swift")
        #expect(XcodeToolIntegration.publicToolName(for: "xcode.XcodeRead") == "xcode.XcodeRead")
        #expect(XcodeToolIntegration.canonicalAllowedToolName("xcode") == "xcode.")
        #expect(XcodeToolIntegration.presentationKind(for: "xcode.XcodeUpdate") == "edit")
        #expect(XcodeToolIntegration.publicDescription("Reads a file") == "Xcode: Reads a file")
    }

    @Test
    func matchesWorkspaceRootsThroughProjectContainers() {
        let context = XcodeWorkspaceContext(
            workspacePath: "/tmp/Workspace/App.xcodeproj",
            defaultTabIdentifier: "tab-1"
        )

        #expect(XcodeToolIntegration.matchedWorkspaceContext(
            in: [context],
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/Workspace")
        ) == context)
        #expect(XcodeToolIntegration.workspaceMatches(
            workspaceRootPath: context.normalizedWorkspaceRootPath,
            preferredWorkspaceRootURL: URL(fileURLWithPath: "/tmp/Workspace/Sources")
        ))
    }
}
