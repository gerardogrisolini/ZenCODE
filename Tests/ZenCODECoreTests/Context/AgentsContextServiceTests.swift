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
