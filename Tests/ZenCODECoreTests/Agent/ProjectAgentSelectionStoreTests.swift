//
//  ProjectAgentSelectionStoreTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

/// Runs `body` with a throwaway support directory and a throwaway workspace,
/// so a test never reads or writes the real `~/.zencode`.
enum ProjectAgentSelectionTestSupport {
    static func withTemporaryProject<T>(
        _ body: (_ supportDirectory: URL, _ workspace: URL) throws -> T
    ) throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-project-agents-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try AppStorageDirectory.withSupportDirectoryURL(support) {
            try body(support, workspace)
        }
    }

    static func withTemporaryProjectAsync<T>(
        _ body: (_ supportDirectory: URL, _ workspace: URL) async throws -> T
    ) async throws -> T {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-project-agents-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        return try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(support, workspace)
        }
    }

    /// System profile: its ID is its role.
    static let developer = AgentProfile(id: "developer", name: "Developer", role: .developer)
    /// Custom profiles: any other ID.
    static let reviewer = AgentProfile(id: "AAAAAAAA-0000-0000-0000-000000000002", name: "Reviewer", role: .reviewer)
    static let reporter = AgentProfile(id: "AAAAAAAA-0000-0000-0000-000000000003", name: "Reporter", role: .reporter)
    static var profiles: [AgentProfile] { [developer, reviewer, reporter] }
    /// What a project without a saved selection sees: the system profiles.
    static var systemProfiles: [AgentProfile] { [developer] }
}

@Suite
struct ProjectAgentSelectionStoreTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    @Test
    func missingFileMeansNoSavedSelectionAndOnlySystemProfiles() throws {
        try Support.withTemporaryProject { support, workspace in
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: workspace) == nil)
            #expect(!FileManager.default.fileExists(
                atPath: ProjectAgentSelectionStore.manifestURL(workspaceRootURL: workspace).path
            ))
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, selection: nil) == Support.systemProfiles)
            #expect(
                ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace)
                    == Support.systemProfiles
            )
            for profile in Support.profiles {
                #expect(ProjectAgentSelectionStore.isAssociated(profile, selection: nil) == profile.isSystemProfile)
                #expect(
                    ProjectAgentSelectionStore.isAssociated(profile, workspaceRootURL: workspace)
                        == profile.isSystemProfile
                )
            }
            let defaults = AgentProfileStore.defaultProfiles()
            let custom = AgentProfile(id: UUID().uuidString, name: "Developer", role: .developer)
            #expect(ProjectAgentSelectionStore.filter(defaults + [custom], selection: nil) == defaults)
            // Reading never creates anything in the support directory.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: support.path)
            #expect(leftovers.isEmpty)
        }
    }

    @Test
    func saveAndLoadRoundTripKeepsOnlyTheSavedProfiles() throws {
        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.reviewer.id, Support.developer.id],
                workspaceRootURL: workspace
            )

            let selection = try #require(ProjectAgentSelectionStore.load(workspaceRootURL: workspace))
            #expect(selection == Set([Support.developer, Support.reviewer].map(ProjectAgentSelectionStore.selectionKey(for:))))
            #expect(
                ProjectAgentSelectionStore.filter(Support.profiles, selection: selection)
                    == [Support.developer, Support.reviewer]
            )
            #expect(ProjectAgentSelectionStore.isAssociated(Support.developer, workspaceRootURL: workspace))
            #expect(!ProjectAgentSelectionStore.isAssociated(Support.reporter, workspaceRootURL: workspace))
        }
    }

    @Test
    func manifestLivesUnderProjectsDigestDirectoryAndRecordsTheWorkspacePath() throws {
        try Support.withTemporaryProject { support, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.reviewer.id, Support.developer.id, Support.reviewer.id.lowercased(), "  "],
                workspaceRootURL: workspace
            )

            let digest = Data(workspace.standardizedFileURL.path.utf8).sha256Hex()
            let expectedURL = support
                .appendingPathComponent("projects", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent("agents.json", isDirectory: false)
                .standardizedFileURL
            let manifestURL = ProjectAgentSelectionStore.manifestURL(workspaceRootURL: workspace)
            #expect(manifestURL == expectedURL)
            #expect(FileManager.default.fileExists(atPath: expectedURL.path))

            let manifest = try JSONDecoder().decode(
                ProjectAgentSelectionStore.Manifest.self,
                from: Data(contentsOf: expectedURL)
            )
            #expect(manifest.version == 1)
            #expect(manifest.workspacePath == workspace.standardizedFileURL.path)
            // De-duplicated by normalized key and written in a stable order.
            #expect(manifest.agentIDs == [Support.reviewer.id, Support.developer.id])

            let text = try #require(String(data: Data(contentsOf: expectedURL), encoding: .utf8))
            #expect(text.contains("\n"))
            let keys = ["agentIDs", "version", "workspacePath"]
            let positions = try keys.map { key in
                try #require(text.range(of: "\"\(key)\"")?.lowerBound)
            }
            #expect(positions == positions.sorted())
        }
    }

    @Test
    func profileMatchingIsCaseInsensitiveOnTheIdentifier() throws {
        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.developer.id.lowercased()],
                workspaceRootURL: workspace
            )
            #expect(ProjectAgentSelectionStore.isAssociated(Support.developer, workspaceRootURL: workspace))
            #expect(
                ProjectAgentSelectionStore.isAssociated(
                    AgentProfile(id: Support.developer.id.uppercased(), name: "Renamed", role: .developer),
                    workspaceRootURL: workspace
                )
            )
            // A caller-supplied set is normalized as well.
            #expect(
                ProjectAgentSelectionStore.filter(
                    Support.profiles,
                    selection: [Support.reviewer.id.lowercased()]
                ) == [Support.reviewer]
            )
        }
    }

    @Test
    func renamedProfileKeepsItsAssociationAndNewProfilesAreNotAddedByThemselves() throws {
        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [Support.developer.id],
                workspaceRootURL: workspace
            )
            let renamed = AgentProfile(id: Support.developer.id, name: "Lead Developer", role: .developer)
            let created = AgentProfile(id: "AAAAAAAA-0000-0000-0000-0000000000FF", name: "Developer", role: .developer)

            #expect(ProjectAgentSelectionStore.isAssociated(renamed, workspaceRootURL: workspace))
            // Same name as an associated profile, different ID: not associated.
            #expect(!ProjectAgentSelectionStore.isAssociated(created, workspaceRootURL: workspace))
            #expect(
                ProjectAgentSelectionStore.filter(
                    Support.profiles + [created],
                    workspaceRootURL: workspace
                ) == [Support.developer]
            )
        }
    }

    @Test
    func blankProfileIdentifierFallsBackToTheName() throws {
        let blank = try JSONDecoder().decode(
            AgentProfile.self,
            from: Data(#"{"id":"  ","name":"Legacy","role":"developer"}"#.utf8)
        )
        #expect(ProjectAgentSelectionStore.selectionIdentifier(for: blank) == "Legacy")

        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(
                agentIDs: [ProjectAgentSelectionStore.selectionIdentifier(for: blank)],
                workspaceRootURL: workspace
            )
            #expect(ProjectAgentSelectionStore.isAssociated(blank, workspaceRootURL: workspace))
            #expect(!ProjectAgentSelectionStore.isAssociated(Support.developer, workspaceRootURL: workspace))
        }
    }

    @Test
    func differentWorkspacesHaveIndependentSelections() throws {
        try Support.withTemporaryProject { support, workspace in
            let other = support.deletingLastPathComponent()
                .appendingPathComponent("other-workspace", isDirectory: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

            try ProjectAgentSelectionStore.save(agentIDs: [Support.developer.id], workspaceRootURL: workspace)

            #expect(
                ProjectAgentSelectionStore.manifestURL(workspaceRootURL: workspace)
                    != ProjectAgentSelectionStore.manifestURL(workspaceRootURL: other)
            )
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: other) == nil)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: other) == Support.systemProfiles)

            try ProjectAgentSelectionStore.save(agentIDs: [Support.reporter.id], workspaceRootURL: other)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace) == [Support.developer])
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: other) == [Support.reporter])
        }
    }

    @Test
    func equivalentWorkspacePathsShareOneFile() throws {
        try Support.withTemporaryProject { _, workspace in
            let roundabout = workspace.appendingPathComponent("sub", isDirectory: true)
                .appendingPathComponent("..", isDirectory: true)
            #expect(
                ProjectAgentSelectionStore.manifestURL(workspaceRootURL: roundabout)
                    == ProjectAgentSelectionStore.manifestURL(workspaceRootURL: workspace)
            )
        }
    }

    @Test
    func emptySavedSelectionDelegatesToNoProfile() throws {
        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(agentIDs: [String](), workspaceRootURL: workspace)

            let selection = try #require(ProjectAgentSelectionStore.load(workspaceRootURL: workspace))
            #expect(selection.isEmpty)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, selection: selection).isEmpty)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace).isEmpty)
            for profile in Support.profiles {
                #expect(!ProjectAgentSelectionStore.isAssociated(profile, workspaceRootURL: workspace))
            }
        }
    }

    @Test
    func savingAgainReplacesThePreviousSelection() throws {
        try Support.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(agentIDs: Support.profiles.map(\.id), workspaceRootURL: workspace)
            try ProjectAgentSelectionStore.save(agentIDs: [Support.reporter.id], workspaceRootURL: workspace)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace) == [Support.reporter])
        }
    }

    @Test
    func corruptOrUnsupportedFileIsTreatedAsAbsent() throws {
        try Support.withTemporaryProject { _, workspace in
            let url = ProjectAgentSelectionStore.manifestURL(workspaceRootURL: workspace)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            try Data("not json".utf8).write(to: url)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: workspace) == nil)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace) == Support.systemProfiles)

            try Data(#"{"version":1,"workspacePath":"/x"}"#.utf8).write(to: url)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: workspace) == nil)

            try Data(#"{"version":99,"workspacePath":"/x","agentIDs":["a"]}"#.utf8).write(to: url)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: workspace) == nil)

            try Data().write(to: url)
            #expect(ProjectAgentSelectionStore.load(workspaceRootURL: workspace) == nil)
            #expect(ProjectAgentSelectionStore.isAssociated(Support.developer, workspaceRootURL: workspace))
            #expect(!ProjectAgentSelectionStore.isAssociated(Support.reporter, workspaceRootURL: workspace))

            // A later save repairs the file.
            try ProjectAgentSelectionStore.save(agentIDs: [Support.developer.id], workspaceRootURL: workspace)
            #expect(ProjectAgentSelectionStore.filter(Support.profiles, workspaceRootURL: workspace) == [Support.developer])
        }
    }
}
