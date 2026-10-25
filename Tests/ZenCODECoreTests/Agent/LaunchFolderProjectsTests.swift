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

    @Test
    func scanUsesTheDefaultLimitOfOneHundredFolders() throws {
        #expect(LaunchFolderProjects.defaultLimit == 100)
        try withTemporaryDirectory { directory in
            for index in 0..<103 {
                try makeDirectory(named: String(format: "project-%03d", index), in: directory)
            }

            let projects = LaunchFolderProjects.scan(workingDirectory: directory)

            #expect(projects.folderNames.count == 100)
            #expect(projects.folderNames.first == "project-000")
            #expect(projects.folderNames.last == "project-099")
            #expect(projects.omittedCount == 3)
        }
    }

    @Test
    func scanBreaksCaseInsensitiveTiesByRawName() throws {
        try withTemporaryDirectory { directory in
            try makeDirectory(named: "dup", in: directory)
            try makeDirectory(named: "Dup", in: directory)
            // A case-insensitive volume keeps one of the two folders.
            let created = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            guard created.count == 2 else {
                return
            }

            let projects = LaunchFolderProjects.scan(workingDirectory: directory)

            #expect(projects.folderNames == ["Dup", "dup"])
        }
    }

    @Test
    func scanOfAMissingOrUnreadableDirectoryIsEmpty() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing", isDirectory: true)
            let file = directory.appendingPathComponent("file.txt")
            try Data("x".utf8).write(to: file)

            for url in [missing, file] {
                let projects = LaunchFolderProjects.scan(workingDirectory: url)
                #expect(projects.folderNames.isEmpty)
                #expect(projects.omittedCount == 0)
                #expect(projects.workingDirectoryPath == url.standardizedFileURL.path)
            }
        }
    }

    #if os(macOS)
    /// Characterizes `skipsHiddenFiles` on macOS, which hides folders carrying
    /// the file-system hidden flag (not only dot-names).
    @Test
    func scanSkipsFoldersFlaggedAsHiddenByTheFileSystem() throws {
        try withTemporaryDirectory { directory in
            try makeDirectory(named: "visible", in: directory)
            try makeDirectory(named: "flagged", in: directory)

            var url = directory.appendingPathComponent("flagged", isDirectory: true)
            var values = URLResourceValues()
            values.isHidden = true
            try url.setResourceValues(values)
            let readBack = try url.resourceValues(forKeys: [.isHiddenKey])
            try #require(readBack.isHidden == true)

            let projects = LaunchFolderProjects.scan(workingDirectory: directory)

            #expect(projects.folderNames == ["visible"])
            #expect(projects.omittedCount == 0)
        }
    }
    #endif

    // MARK: - Section text

    @Test
    func sectionListsTheFoldersWithTheWorkingDirectoryInstruction() {
        let section = SystemPromptBuilder.launchFolderProjectsSection(
            LaunchFolderProjects(
                workingDirectoryPath: "/Users/me/Projects",
                folderNames: ["alpha", "Bravo"],
                omittedCount: 0
            )
        )

        #expect(section == """
        Projects in the launch folder:
        Folders directly inside /Users/me/Projects, read when this agent was selected (a folder created later appears after the agent is selected again). To work on one, pass `/Users/me/Projects/<name>` (or just `<name>`) as `workingDirectory`:
        - alpha
        - Bravo
        """)
    }

    @Test
    func sectionCountsTheFoldersThatAreNotListed() {
        let section = SystemPromptBuilder.launchFolderProjectsSection(
            LaunchFolderProjects(
                workingDirectoryPath: "/Users/me/Projects",
                folderNames: ["alpha"],
                omittedCount: 7
            )
        )

        #expect(section.hasSuffix("\n- alpha\n(7 more folders not listed.)"))
    }

    @Test
    func sectionOfAnEmptyListingSaysThatNoFolderWasFound() {
        let section = SystemPromptBuilder.launchFolderProjectsSection(
            LaunchFolderProjects(
                workingDirectoryPath: "/Users/me/Projects",
                folderNames: [],
                omittedCount: 0
            )
        )

        #expect(section == """
        Projects in the launch folder:
        No folders were found directly inside /Users/me/Projects when this agent was selected.
        """)
    }

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
    func theLaunchFolderListingIsIndependentOfTheModelLockAndTheToolGrant() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try makeDirectory(named: "alpha", in: workspace)

            let locked = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                locksModelToSession: true,
                selectedAgentRole: .organizer
            ).dynamicContext
            #expect(!locked.contains("Delegation by role:"))
            #expect(locked.contains("\(Self.headline)\nFolders directly inside "))
            #expect(locked.contains("\n- alpha"))

            let withoutDelegation = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: ["local.readFile"],
                selectedAgentRole: .organizer
            ).dynamicContext
            #expect(!withoutDelegation.contains("Delegation by role:"))
            #expect(withoutDelegation.contains("\(Self.headline)\nFolders directly inside "))
            #expect(withoutDelegation.contains("\n- alpha"))

            let combined = AgentStandaloneSystemPrompt.prompt(
                cwd: workspace.path,
                selectedAgentRole: .organizer
            )
            #expect(combined.contains("\(Self.headline)\nFolders directly inside "))
        }
    }

    @Test
    func anExplicitSnapshotIsUsedVerbatimWithoutReadingTheFolder() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try makeDirectory(named: "on-disk", in: workspace)
            let snapshot = LaunchFolderProjects(
                workingDirectoryPath: "/virtual/launch",
                folderNames: ["ghost-a", "ghost-b"],
                omittedCount: 3
            )
            let recorder = DirectoryListingRecorder()

            let context = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer,
                launchFolderProjects: snapshot,
                listLaunchFolder: recorder.list
            ).dynamicContext

            #expect(context.contains(SystemPromptBuilder.launchFolderProjectsSection(snapshot)))
            #expect(context.contains("\n- ghost-a\n- ghost-b\n(3 more folders not listed.)"))
            #expect(!context.contains("on-disk"))
            #expect(!recorder.listedPaths.contains(workspace.standardizedFileURL.path))

            // Without a snapshot the folder is read now.
            let scanned = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer,
                listLaunchFolder: recorder.list
            ).dynamicContext
            #expect(scanned.contains("\n- on-disk"))
            #expect(!scanned.contains("ghost-a"))
            #expect(recorder.listedPaths.contains(workspace.standardizedFileURL.path))
        }
    }

    @Test
    func anEmptyLaunchFolderIsReportedAsSuch() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            let path = workspace.standardizedFileURL.path

            let scanned = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer
            ).dynamicContext
            #expect(scanned.contains(
                "\(Self.headline)\nNo folders were found directly inside \(path) when this agent was selected."
            ))

            let explicit = AgentStandaloneSystemPrompt.promptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgentRole: .organizer,
                launchFolderProjects: LaunchFolderProjects(
                    workingDirectoryPath: "/virtual/launch",
                    folderNames: [],
                    omittedCount: 0
                )
            ).dynamicContext
            #expect(explicit.contains(
                "\(Self.headline)\nNo folders were found directly inside /virtual/launch when this agent was selected."
            ))
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

    @Test
    func compositionEntryPointsForwardTheSnapshotOnlyToAnOrganizer() throws {
        try Support.withTemporaryProject { _, workspace in
            try AgentProfileStore.save(Support.profiles + [Self.organizer])
            try makeDirectory(named: "on-disk", in: workspace)
            let snapshot = LaunchFolderProjects(
                workingDirectoryPath: "/virtual/launch",
                folderNames: ["ghost"],
                omittedCount: 0
            )
            let expected = SystemPromptBuilder.launchFolderProjectsSection(snapshot)

            let standard = AgentSessionComposition.standardPromptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgent: Self.organizer,
                launchFolderProjects: snapshot
            )
            #expect(standard.dynamicContext.contains(expected))
            #expect(standard.combinedPrompt.contains(expected))
            #expect(
                AgentSessionComposition.standardSystemPrompt(
                    cwd: workspace.path,
                    allowedToolNames: nil,
                    selectedAgent: Self.organizer,
                    launchFolderProjects: snapshot
                ).contains(expected)
            )

            let appProvided = AgentSessionComposition.appProvidedPromptSections(
                "App instructions",
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgent: Self.organizer,
                launchFolderProjects: snapshot
            )
            #expect(appProvided.dynamicContext.contains(expected))
            #expect(
                AgentSessionComposition.appProvidedSystemPrompt(
                    "App instructions",
                    cwd: workspace.path,
                    allowedToolNames: nil,
                    selectedAgent: Self.organizer,
                    launchFolderProjects: snapshot
                ).contains(expected)
            )

            // Without a snapshot the folder is read at composition time.
            let scanned = AgentSessionComposition.standardPromptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgent: Self.organizer
            )
            #expect(scanned.dynamicContext.contains("\n- on-disk"))

            // Without a working directory there is no folder to list.
            let withoutCwd = AgentSessionComposition.appProvidedPromptSections(
                "App instructions",
                allowedToolNames: nil,
                selectedAgent: Self.organizer,
                launchFolderProjects: snapshot
            )
            #expect(!withoutCwd.dynamicContext.contains(Self.headline))

            // Another role never gets the listing.
            let developer = AgentSessionComposition.standardPromptSections(
                cwd: workspace.path,
                allowedToolNames: nil,
                selectedAgent: Support.developer,
                launchFolderProjects: snapshot
            )
            #expect(!developer.combinedPrompt.contains(Self.headline))
        }
    }

    #if os(macOS)
    @Test
    func theRecommendedOrganizerInstructionsPointToTheLaunchFolderList() throws {
        let instructions = try #require(
            AgentProfileStore.defaultProfiles()
                .first { $0.role == .organizer }?.instructions
        )

        #expect(instructions.contains(
            "Take the folder from the `Projects in the launch folder` list in your context or from memory; "
                + "if it is in neither, ask the user once and record it as an `entity`."
        ))
        #expect(!instructions.contains("Take the folder from memory; if it is unknown"))
    }
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
