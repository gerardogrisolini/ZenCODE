import FeatureKit
import Foundation
import ToolCore
@testable import XcodeToolsFeature
import Testing

@Suite
struct XcodeToolIntegrationTests {
    @Test
    func canonicalizesPublicAliasesWithoutSendingPrefixToMCP() throws {
        let request = try #require(XcodeToolIntegration.normalizedRequest(
            ToolRequest(
                name: "xcode.XcodeRead",
                arguments: ["path": .string("Sources/App.swift")]
            )
        ))

        for alias in ["XcodeRead", "xcode.read", "xcode.XcodeRead"] {
            #expect(
                XcodeToolIntegration.normalizedRequest(ToolRequest(name: alias, arguments: [:]))?.name
                    == "XcodeRead"
            )
        }
        #expect(request.name == "XcodeRead")
        #expect(request.arguments["filePath"]?.stringValue == "Sources/App.swift")
        #expect(XcodeToolIntegration.rawToolName(fromPublicName: "xcode.XcodeRead") == "XcodeRead")
        #expect(XcodeToolIntegration.rawToolName(fromPublicName: "XcodeRead") == "XcodeRead")
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
    func normalizesWorkspaceRootsThroughProjectContainers() {
        let context = XcodeWorkspaceContext(
            workspacePath: "/tmp/Workspace/App.xcodeproj",
            defaultTabIdentifier: "tab-1"
        )

        #expect(context.normalizedWorkspaceRootPath == "/tmp/Workspace")
        #expect(XcodeWorkspaceContext.normalizedProjectRootPath(
            explicitPath: nil,
            workspacePath: "/tmp/Workspace/App.xcworkspace/"
        ) == "/tmp/Workspace")
    }

    @Test
    func updatePresentationBindsTheDiffToTheBridgeArgumentNames() throws {
        let presentation = XcodeToolIntegration.presentation(for: ToolDescriptor(
            name: "xcode.XcodeUpdate",
            description: "Edit",
            inputSchema: "{}",
            presentation: .standard(title: "Xcode file", action: "Edit", kind: .edit)
        ))
        let encoded = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(presentation)
        ) as? [String: Any]
        let sections = try #require(encoded?["sections"] as? [[String: Any]])
        let diff = try #require(sections.first { $0["kind"] as? String == "diff" })
        let oldKeys = try #require((diff["oldValue"] as? [String: Any])?["keyPaths"] as? [String])
        let newKeys = try #require((diff["newValue"] as? [String: Any])?["keyPaths"] as? [String])

        #expect(oldKeys.first == "oldString")
        #expect(newKeys.first == "newString")
        #expect(oldKeys.contains("old") && newKeys.contains("new"))
    }

    @Test
    func runToolsAreNotPresentedAsShellCommands() {
        for rawName in ["BuildProject", "RunAllTests", "RunSomeTests", "ExecuteSnippet", "RenderPreview"] {
            let publicName = "xcode.\(rawName)"
            let presentation = XcodeToolIntegration.presentation(for: ToolDescriptor(
                name: publicName,
                description: rawName,
                inputSchema: "{}"
            ))

            #expect(XcodeToolIntegration.presentationKind(for: publicName) == "other")
            #expect(presentation.kind == .other)
            #expect(presentation.action == "Run")
        }
    }

    @Test
    func listWindowsResultsWithoutWorkspacesAreIgnoredSafely() {
        #expect(XcodeWorkspaceContext.contexts(fromListWindowsResult: .string("oops")).isEmpty)
        #expect(XcodeWorkspaceContext.contexts(fromListWindowsResult: .object([
            "isError": .bool(true),
            "structuredContent": .object(["windows": .array([.object(["tabIdentifier": .string("t")])])])
        ])).isEmpty)
        #expect(XcodeWorkspaceContext.contexts(fromListWindowsResult: .object([
            "structuredContent": .object(["windows": .array([.string("not an object"), .null])])
        ])).isEmpty)
        let message = XcodeWorkspaceContext.contexts(fromListWindowsResult: .object([
            "structuredContent": .object([
                "message": .string("Windows:\n* tabIdentifier: t1, workspacePath: /tmp/P/P.xcodeproj\n* junk")
            ])
        ]))
        #expect(message == [XcodeWorkspaceContext(workspacePath: "/tmp/P", defaultTabIdentifier: "t1")])
    }
}
