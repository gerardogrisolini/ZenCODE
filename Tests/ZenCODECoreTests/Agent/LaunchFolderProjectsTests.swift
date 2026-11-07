//
//  LaunchFolderProjectsTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct LaunchFolderProjectsTests {
    private typealias Support = ProjectAgentSelectionTestSupport

    /// System profile of the organizer role.
    private static let organizer = AgentProfile(
        id: "organizer",
        name: "Organizer",
        role: .organizer
    )

    private static let headline = "Projects in the launch folder:"

    // MARK: - Scan

    @Test
    func scanListsVisibleFoldersSortedIgnoringCase() throws {
        try withTemporaryDirectory { directory in
            for name in ["Zulu", "alpha", "Bravo", "charlie"] {
                try makeDirectory(named: name, in: directory)
            }

            let projects = LaunchFolderProjects.scan(workingDirectory: directory)

            #expect(projects.folderNames == ["alpha", "Bravo", "charlie", "Zulu"])
            #expect(projects.omittedCount == 0)
            #expect(projects.workingDirectoryPath == directory.standardizedFileURL.path)
        }
    }

    @Test
    func scanSkipsHiddenFoldersFilesNestedFoldersAndSymlinks() throws {
        try withTemporaryDirectory { directory in
            let fileManager = FileManager.default
            try makeDirectory(named: "visible", in: directory)
            try makeDirectory(named: ".hidden", in: directory)
            try makeDirectory(named: ".git", in: directory)
            try makeDirectory(named: "visible/nested", in: directory)
            try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))
            // A symlink to a folder is not followed, so it is not a project.
            try fileManager.createSymbolicLink(
                at: directory.appendingPathComponent("link-to-visible"),
                withDestinationURL: directory.appendingPathComponent("visible")
            )
            try fileManager.createSymbolicLink(
                at: directory.appendingPathComponent("dangling"),
                withDestinationURL: directory.appendingPathComponent("missing")
            )

            let projects = LaunchFolderProjects.scan(workingDirectory: directory)

            #expect(projects.folderNames == ["visible"])
            #expect(projects.omittedCount == 0)
        }
    }

    @Test
    func scanKeepsTheFirstFoldersUpToTheLimitAndCountsTheRest() throws {
        try withTemporaryDirectory { directory in
            for name in ["e", "b", "d", "a", "c"] {
                try makeDirectory(named: name, in: directory)
            }

            let limited = LaunchFolderProjects.scan(workingDirectory: directory, limit: 3)
            #expect(limited.folderNames == ["a", "b", "c"])
            #expect(limited.omittedCount == 2)

            let exact = LaunchFolderProjects.scan(workingDirectory: directory, limit: 5)
            #expect(exact.folderNames == ["a", "b", "c", "d", "e"])
            #expect(exact.omittedCount == 0)

            let generous = LaunchFolderProjects.scan(workingDirectory: directory, limit: 50)
            #expect(generous.folderNames.count == 5)
            #expect(generous.omittedCount == 0)

            let none = LaunchFolderProjects.scan(workingDirectory: directory, limit: 0)
            #expect(none.folderNames.isEmpty)
            #expect(none.omittedCount == 5)
        }
    }

    #if os(macOS)
    #endif

    // MARK: - Prompt composition

    @Test
    func organizerPromptListsTheLaunchFolderProjectsAfterTheRoleDelegation() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            for name in ["Zulu", "alpha", ".hidden"] {
                try makeDirectory(named: name, in: workspace)
            }
            try Data("notes".utf8).write(to: workspace.appendingPathComponent("notes.txt"))

            let sections = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            )

            let context = sections.dynamicContext
            let expected = SystemPromptBuilder.launchFolderProjectsSection(
                LaunchFolderProjects(
                    workingDirectoryPath: workspace.standardizedFileURL.path,
                    folderNames: ["alpha", "Zulu"],
                    omittedCount: 0
                )
            )
            #expect(context.contains(expected))
            #expect(context.contains("\(Self.headline)\nFolders directly inside "))
            #expect(!context.contains(".hidden"))
            #expect(!context.contains("notes.txt"))
            // It follows the role-delegation section and lives in the context.
            let delegation = try #require(context.range(of: "Delegation by role:"))
            let listing = try #require(context.range(of: Self.headline))
            #expect(delegation.lowerBound < listing.lowerBound)
            #expect(!sections.systemPrompt.contains(Self.headline))
            #expect(sections.combinedPrompt.contains(expected))
        }
    }

    @Test
    func rolesThatDoNotDelegateByRoleGetNoListingAndNoScan() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try makeDirectory(named: "alpha", in: workspace)
            let recorder = DirectoryListingRecorder()
            let snapshot = LaunchFolderProjects(
                workingDirectoryPath: "/virtual/launch",
                folderNames: ["ghost"],
                omittedCount: 0
            )

            for role in AgentProfileRole.allCases + [nil] where role?.delegatesByRole != true {
                for launchFolderProjects in [nil, snapshot] {
                    let context = AgentStandaloneSystemPrompt.promptSections(
                        cwd: workspace.path,
                        allowedToolNames: nil,
                        selectedAgentRole: role,
                        launchFolderProjects: launchFolderProjects,
                        listLaunchFolder: recorder.list
                    ).dynamicContext
                    #expect(!context.contains(Self.headline))
                    #expect(!context.contains("ghost"))
                }
            }
            #expect(!recorder.listedPaths.contains(workspace.standardizedFileURL.path))
        }
    }

    #if os(macOS)
    #endif
}

// MARK: - Helpers

private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("zencode-launch-folder-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

private func makeDirectory(named name: String, in directory: URL) throws {
    try FileManager.default.createDirectory(
        at: directory.appendingPathComponent(name, isDirectory: true),
        withIntermediateDirectories: true
    )
}

/// Records the directories that are listed, to prove when the launch folder is read.
private final class DirectoryListingRecorder: Sendable {
    private let listed = Mutex<[String]>([])

    var listedPaths: [String] {
        listed.withLock { $0 }
    }

    func list(_ path: String) throws -> [String] {
        listed.withLock { $0.append(URL(fileURLWithPath: path).standardizedFileURL.path) }
        return try LaunchFolderProjects.defaultListDirectory(atPath: path)
    }
}
