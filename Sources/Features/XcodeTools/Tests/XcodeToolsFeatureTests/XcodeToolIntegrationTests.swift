import FeatureMCPBridgeKit
import FeatureKit
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
        let preferredDescription = XcodeToolIntegration.publicDescription("Reads a file")
        #expect(preferredDescription.hasPrefix(XcodeToolIntegration.priorityDescriptionPrefix))
        #expect(preferredDescription.hasSuffix("Reads a file"))
        #expect(XcodeToolIntegration.publicDescription("Xcode: Reads a file") == preferredDescription)
        #expect(XcodeToolIntegration.publicDescription(preferredDescription) == preferredDescription)
    }

    @Test
    func featureDescriptorPublishesXcodePriorityOnlyFromOptionalPackage() throws {
        let source = ToolDescriptor(
            name: "xcode.XcodeRead",
            title: "Xcode file",
            description: "Reads a file from the current Xcode project.",
            inputSchema: "{}",
            presentation: .standard(
                title: "Xcode file",
                action: "Read",
                kind: .read
            )
        )

        let descriptor = XcodeToolsFeatureRunner.featureToolDescriptor(for: source)

        #expect(descriptor.name == source.name)
        #expect(descriptor.description.hasPrefix(XcodeToolIntegration.priorityDescriptionPrefix))
        #expect(descriptor.description.contains("generic shell"))
        #expect(descriptor.description.contains("xcodebuild"))
        #expect(descriptor.description.hasSuffix(source.description))
        #expect(descriptor.inputSchema == source.inputSchema)
        #expect(descriptor.presentation == XcodeToolIntegration.presentation(for: source))
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
