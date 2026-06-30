//
//  MLXAgentsContextServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//
import Foundation
import ZenCODECore
import Testing

@Suite
struct MLXAgentsContextServiceTests {
    @Test
    func globalAgentsTemplateFramesAssistantBehavior() {
        let content = MLXAgentsContextService.defaultGlobalAgentsContent

        #expect(content.contains("do what the user asked"))
        #expect(content.contains("on the user's machine"))
        #expect(!content.contains("on the user's Mac"))
        #expect(content.contains("do not invent extra requirements"))
        #expect(content.contains("Briefly explain the intent behind non-obvious or risky actions"))
        #expect(content.contains("prepare a concise implementation plan"))
        #expect(content.contains("files or areas expected to change"))
        #expect(content.contains("validation you expect to run"))
        #expect(content.contains("Do not modify files until the user approves the plan"))
        #expect(content.contains("verify the plan point by point"))
        #expect(content.contains("report validation results"))
        #expect(content.contains("Ask focused questions when they help"))
    }

    @Test
    func projectAgentsTemplateDoesNotAssumeSharedXcodeSchemes() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: rootURL.appendingPathComponent("Package.swift"))

        let content = MLXProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "PackageOnly",
            rootPath: rootURL.path
        )

        #expect(content.contains("Keep only durable project-specific facts"))
        #expect(content.contains("Use this file to quickly re-enter the project after reopening the folder."))
        #expect(content.contains("SwiftPM target roots are under `Sources/<target>` and `Tests/<target>`"))
        #expect(content.contains("Use the package manifests listed above"))
        #expect(!content.contains("Use the shared schemes listed above"))
    }

    @Test
    func projectAgentsTemplateUsesSharedSchemesWhenDetected() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        let schemesURL = rootURL
            .appendingPathComponent("App.xcodeproj", isDirectory: true)
            .appendingPathComponent("xcshareddata/xcschemes", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(
            at: schemesURL,
            withIntermediateDirectories: true
        )
        try Data().write(to: schemesURL.appendingPathComponent("App.xcscheme"))

        let content = MLXProjectContextFileService.defaultContent(
            kind: .agents,
            projectName: "XcodeApp",
            rootPath: rootURL.path
        )

        #expect(content.contains("- Shared schemes: App."))
        #expect(content.contains("Use the shared schemes listed above for XcodeApp build and test verification."))
    }

    @Test
    func promptSectionFiltersProjectMetaGuidance() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-agents-tests-\(UUID().uuidString)", isDirectory: true)
        let globalURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
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
            to: workspaceURL.appendingPathComponent(MLXAgentsContextService.filename),
            atomically: true,
            encoding: .utf8
        )

        let prompt = MLXAgentsContextService(globalAgentsDirectoryURL: globalURL)
            .promptSection(workspaceRootURL: workspaceURL)

        #expect(prompt?.contains("Global context:") == true)
        #expect(prompt?.contains("Project context:") == true)
        #expect(prompt?.contains("Confirmed command: swift test.") == true)
        #expect(prompt?.contains("editor guidance") == false)
    }
}
