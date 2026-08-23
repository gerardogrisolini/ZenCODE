//
//  PromptSkillInstallerTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct PromptSkillInstallerTests {
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
            .appendingPathComponent("skill-installer-tests-\(UUID().uuidString)", isDirectory: true)
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
    func uninstallRemovesSelectedSkillAndLeavesOtherInstalledSkills() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        let installedRootURL = rootURL.appendingPathComponent("skills", isDirectory: true)
        let removeURL = installedRootURL.appendingPathComponent("remove-me", isDirectory: true)
        let keepURL = installedRootURL.appendingPathComponent("keep-me", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: removeURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: keepURL,
            withIntermediateDirectories: true
        )
        try "# Remove Me\nRemove this skill."
            .write(
                to: removeURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        try "# Keep Me\nKeep this skill."
            .write(
                to: keepURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )

        let skills = PromptSkillCatalog.discoverSkills(searchRoots: [installedRootURL])
        let selected = try #require(skills.first(where: { $0.title == "Remove Me" }))

        try PromptSkillInstaller.uninstall(
            skills: [selected],
            allowedRoots: [installedRootURL]
        )

        #expect(!FileManager.default.fileExists(atPath: removeURL.path))
        #expect(FileManager.default.fileExists(atPath: keepURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: keepURL.appendingPathComponent("SKILL.md").path
            )
        )
    }

    @Test
    func uninstallRejectsCatalogRootAndSkillOutsideAllowedRoot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-uninstall-safety-\(UUID().uuidString)", isDirectory: true)
        let installedRootURL = rootURL.appendingPathComponent("skills", isDirectory: true)
        let outsideURL = rootURL.appendingPathComponent("outside", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: installedRootURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideURL,
            withIntermediateDirectories: true
        )
        let markdown = "# Safety Skill\nKeep the catalog safe."
        try markdown.write(
            to: installedRootURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try markdown.write(
            to: outsideURL.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )

        let catalogSkill = try #require(
            PromptSkillCatalog.discoverSkills(searchRoots: [installedRootURL]).first
        )
        let outsidePayload = try PromptSkillMarkdownParser.parse(
            url: outsideURL.appendingPathComponent("SKILL.md")
        )
        let outsideSkill = PromptSkill(payload: outsidePayload)

        #expect(throws: PromptSkillInstallerError.self) {
            try PromptSkillInstaller.uninstall(
                skills: [catalogSkill],
                allowedRoots: [installedRootURL]
            )
        }
        #expect(throws: PromptSkillInstallerError.self) {
            try PromptSkillInstaller.uninstall(
                skills: [outsideSkill],
                allowedRoots: [installedRootURL]
            )
        }
        #expect(FileManager.default.fileExists(atPath: installedRootURL.path))
        #expect(FileManager.default.fileExists(atPath: outsideURL.path))
    }

    @Test
    func uninstallRejectsSymlinkedCatalogRoot() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-uninstall-symlink-root-\(UUID().uuidString)", isDirectory: true)
        let physicalRootURL = rootURL.appendingPathComponent("physical", isDirectory: true)
        let catalogRootURL = rootURL.appendingPathComponent("skills", isDirectory: true)
        let skillURL = physicalRootURL.appendingPathComponent("keep-me", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: skillURL,
            withIntermediateDirectories: true
        )
        try "# Keep Me\nDo not remove this skill."
            .write(
                to: skillURL.appendingPathComponent("SKILL.md"),
                atomically: true,
                encoding: .utf8
            )
        try FileManager.default.createSymbolicLink(
            at: catalogRootURL,
            withDestinationURL: physicalRootURL
        )

        let payload = try PromptSkillMarkdownParser.parse(
            url: catalogRootURL
                .appendingPathComponent("keep-me", isDirectory: true)
                .appendingPathComponent("SKILL.md")
        )
        let skill = PromptSkill(payload: payload)

        #expect(throws: PromptSkillInstallerError.self) {
            try PromptSkillInstaller.uninstall(
                skills: [skill],
                allowedRoots: [catalogRootURL]
            )
        }
        #expect(FileManager.default.fileExists(atPath: skillURL.path))
        #expect(
            FileManager.default.fileExists(
                atPath: skillURL.appendingPathComponent("SKILL.md").path
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
        #expect(TerminalChat.isSkillUninstallRequest("uninstall") == true)
        #expect(TerminalChat.isSkillUninstallRequest("UNINSTALL") == true)
        #expect(TerminalChat.isSkillUninstallRequest("uninstall skill") == false)
    }
}
