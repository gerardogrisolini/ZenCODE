//
//  MLXPromptSkillInstallerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct MLXPromptSkillInstallerTests {
    @Test
    func githubSourceParsesRepositoryURL() throws {
        let source = try GitHubSkillSource(
            url: #require(URL(string: "https://github.com/example/skill-repo"))
        )
        let gitURLSource = try GitHubSkillSource(
            url: #require(URL(string: "https://github.com/example/skill-repo.git"))
        )

        #expect(source.owner == "example")
        #expect(source.repository == "skill-repo")
        #expect(source.cloneURL.absoluteString == "https://github.com/example/skill-repo.git")
        #expect(source.selector == nil)
        #expect(gitURLSource.repository == "skill-repo")
    }

    @Test
    func githubSourceParsesTreeURLWithNestedSkillPath() throws {
        let source = try GitHubSkillSource(
            url: #require(URL(string: "https://github.com/example/skills/tree/main/tools/browser"))
        )

        #expect(source.owner == "example")
        #expect(source.repository == "skills")
        #expect(
            source.selector == GitHubSkillSource.Selector(
                kind: .tree,
                components: ["main", "tools", "browser"]
            )
        )
    }

    @Test
    func githubSourceParsesBlobURLForSkillMarkdown() throws {
        let source = try GitHubSkillSource(
            url: #require(URL(string: "https://github.com/example/skills/blob/release/v1/browser/SKILL.md"))
        )

        #expect(
            source.selector == GitHubSkillSource.Selector(
                kind: .blob,
                components: ["release", "v1", "browser", "SKILL.md"]
            )
        )
    }

    @Test
    func destinationDirectoryNameIsStableAndFilesystemSafe() {
        let payload = PromptSkillPayload(
            canonicalName: "UI Polish++",
            title: "UI Polish",
            summary: "Tighten terminal rendering.",
            rawMarkdown: "# UI Polish\n",
            promptBody: "Tighten terminal rendering.",
            sourceFilename: "SKILL.md",
            sourceHash: "abc123"
        )

        #expect(PromptSkillInstaller.destinationDirectoryName(for: payload) == "ui-polish")
    }

    @Test
    func localInstallCopiesSkillDirectoryToDestinationRoot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-skill-installer-tests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("Source Skill", isDirectory: true)
        let assetsURL = sourceURL.appendingPathComponent("assets", isDirectory: true)
        let destinationRootURL = rootURL.appendingPathComponent("Installed Skills", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: assetsURL,
            withIntermediateDirectories: true
        )
        try """
        ---
        name: Local Skill
        description: Imported from disk.
        ---

        # Local Skill

        Use local instructions.
        """
        .write(
            to: sourceURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try "asset".write(
            to: assetsURL.appendingPathComponent("example.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try PromptSkillInstaller.install(
            fromLocalURL: sourceURL,
            destinationRootURL: destinationRootURL
        )
        let installedURL = destinationRootURL.appendingPathComponent("local-skill", isDirectory: true)

        #expect(result.skill.title == "Local Skill")
        #expect(result.destinationURL.path == installedURL.path)
        #expect(FileManager.default.fileExists(atPath: installedURL.appendingPathComponent("SKILL.md").path))
        #expect(
            FileManager.default.fileExists(
                atPath: installedURL
                    .appendingPathComponent("assets", isDirectory: true)
                    .appendingPathComponent("example.txt")
                    .path
            )
        )
    }

    @Test
    func terminalSkillsCommandRecognizesInstallURLs() throws {
        let baseDirectory = URL(fileURLWithPath: "/tmp/ZenCODE", isDirectory: true)
        let directURL = try #require(
            TerminalChat.githubSkillInstallURL(from: "https://github.com/example/skill")
        )
        let installURL = try #require(
            TerminalChat.githubSkillInstallURL(from: "install https://github.com/example/skill/tree/main")
        )
        let absoluteLocalURL = try #require(
            TerminalChat.localSkillInstallURL(
                from: "/Users/gerardo/path/to/skill",
                baseDirectory: baseDirectory
            )
        )
        let relativeLocalURL = try #require(
            TerminalChat.localSkillInstallURL(
                from: "install ./skills/local",
                baseDirectory: baseDirectory
            )
        )

        #expect(directURL.absoluteString == "https://github.com/example/skill")
        #expect(installURL.absoluteString == "https://github.com/example/skill/tree/main")
        #expect(absoluteLocalURL.path == "/Users/gerardo/path/to/skill")
        #expect(relativeLocalURL.path == "/tmp/ZenCODE/skills/local")
        #expect(TerminalChat.githubSkillInstallURL(from: "ui-polish") == nil)
        #expect(TerminalChat.localSkillInstallURL(from: "ui-polish", baseDirectory: baseDirectory) == nil)
        #expect(TerminalChat.isSkillInstallRequest("install") == true)
    }
}
