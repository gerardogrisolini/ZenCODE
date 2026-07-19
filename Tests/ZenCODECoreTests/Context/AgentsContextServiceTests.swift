//
//  AgentsContextServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ZenCODECore
import Testing

@Suite
struct AgentsContextServiceTests {
    @Test
    func globalAgentsTemplateFramesAssistantBehavior() {
        let content = AgentsContextService.defaultGlobalAgentsContent

        #expect(content.contains("do what the user asked"))
        #expect(content.contains("on the user's machine"))
        #expect(!content.contains("on the user's Mac"))
        #expect(content.contains("do not invent extra requirements"))
        #expect(content.contains("Briefly explain the intent behind non-obvious or risky actions"))
        #expect(content.contains("Ask focused questions when they help"))
        #expect(!content.contains("response-language"))
        #expect(!content.contains("operating system language"))
        #expect(!content.contains("user's active language"))
        #expect(!content.contains("prepare a concise implementation plan"))
        #expect(!content.contains("verify the plan point by point"))
        #expect(!content.contains("approves the plan"))
    }

    @Test
    func compatibilityAgentsDefaultDoesNotInferWorkspaceFacts() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agents-default-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: rootURL.appendingPathComponent(
                "Something.xcodeproj/xcshareddata/xcschemes",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try Data().write(to: rootURL.appendingPathComponent("Package.swift"))

        let content = ProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "AssumedProject",
            rootPath: rootURL.path
        )

        #expect(content == "# AGENTS.md\n")
        #expect(!content.contains("AssumedProject"))
        #expect(!content.contains(rootURL.path))
        #expect(!content.contains("Swift"))
        #expect(!content.contains("Xcode"))
        #expect(!content.contains("Build"))
    }

    @Test
    func promptSectionFiltersProjectMetaGuidance() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agents-service-tests-\(UUID().uuidString)",
                isDirectory: true
            )
        let globalURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let projectContent = """
        # AGENTS.md

        ## Project

        - Name: Demo

        ## Project Guidance

        - Keep only durable project-specific facts here.
        - Confirmed command: swift test.

        ## Context Strategy

        - This line is editor guidance and should not enter the runtime prompt.
        """
        try projectContent.write(
            to: workspaceURL.appendingPathComponent(AgentsContextService.filename),
            atomically: true,
            encoding: .utf8
        )

        let prompt = AgentsContextService(globalAgentsDirectoryURL: globalURL)
            .promptSection(workspaceRootURL: workspaceURL)

        #expect(prompt?.contains("Global context:") == true)
        #expect(prompt?.contains("Project context:") == true)
        #expect(prompt?.contains("Confirmed command: swift test.") == true)
        #expect(prompt?.contains("editor guidance") == false)
    }
}
