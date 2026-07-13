//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentConfigurationTests {
    @Test
    func explicitWorkingDirectoryIsNeverReplacedByLaunchFallbacks() throws {
        let executableURL = try #require(Bundle.main.executableURL)
        let explicitDirectory = executableURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let configuration = try AgentConfiguration(
            arguments: [
                "zen",
                "--help",
                "--cwd",
                explicitDirectory.path,
            ]
        )

        #expect(configuration.workingDirectory == explicitDirectory)
        #expect(
            AgentConfiguration.resolvedWorkingDirectory(
                rawValue: explicitDirectory.path,
                applyLaunchDirectoryFallback: false
            ) == explicitDirectory
        )
    }
}
