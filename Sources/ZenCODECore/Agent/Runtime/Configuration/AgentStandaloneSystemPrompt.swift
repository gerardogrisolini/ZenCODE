//
//  AgentStandaloneSystemPrompt.swift
//  ZenCODE
//
//  Composition of the system prompt of a standalone agent session.
//

import ToolCore
import Foundation

public enum AgentStandaloneSystemPrompt {
    /// Combined form of `promptSections`; `launchFolderProjects` behaves as
    /// documented there.
    public static func prompt(
        cwd: String,
        memoryToolEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        locksModelToSession: Bool = false,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedAgentRole: AgentProfileRole? = nil,
        launchFolderProjects: LaunchFolderProjects? = nil,
        listLaunchFolder: (String) throws -> [String] = LaunchFolderProjects.defaultListDirectory,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil
    ) -> String {
        promptSections(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            locksModelToSession: locksModelToSession,
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL,
            selectedAgentSection: selectedAgentSection,
            selectedAgentRole: selectedAgentRole,
            launchFolderProjects: launchFolderProjects,
            listLaunchFolder: listLaunchFolder,
            selectedSkillSection: selectedSkillSection,
            responseLanguageSection: responseLanguageSection
        )
        .combinedPrompt
    }

    /// Composes the stable system prefix and the session's dynamic context.
    ///
    /// - Parameter launchFolderProjects: Only read when `selectedAgentRole`
    ///   delegates by role (``AgentProfileRole/delegatesByRole``); other roles
    ///   never get the listing and never touch the filesystem for it. The
    ///   listing is a snapshot of the folders directly inside `cwd`. A `nil`
    ///   value scans `cwd` now, so callers that compose once per session (ACP
    ///   `newSession`/load/agent mention, `AgentCoreAppSessionFactory`) read it
    ///   at selection time, while callers that recompose the prompt per turn
    ///   must pass the snapshot they took at selection time.
    /// - Parameter listLaunchFolder: Lists the entries of `cwd` when
    ///   `launchFolderProjects` is `nil` and the role delegates by role. The
    ///   default reads the file system; tests inject it to observe the listing.
    /// - Parameter worktreeSection: The Git worktree section of a session
    ///   whose `cwd` is a `--worktree` worktree
    ///   (``SystemPromptBuilder/worktreeSection(name:path:)``), placed right
    ///   after the working-directory section; `nil` otherwise.
    public static func promptSections(
        cwd: String,
        memoryToolEnabled: Bool = false,
        allowedToolNames: Set<String>? = nil,
        locksModelToSession: Bool = false,
        fileManager: FileManager = .default,
        globalAgentsDirectoryURL: URL? = nil,
        selectedAgentSection: String? = nil,
        selectedAgentRole: AgentProfileRole? = nil,
        launchFolderProjects: LaunchFolderProjects? = nil,
        listLaunchFolder: (String) throws -> [String] = LaunchFolderProjects.defaultListDirectory,
        selectedSkillSection: String? = nil,
        responseLanguageSection: String? = nil,
        worktreeSection: String? = nil
    ) -> SystemPromptSections {
        let workingDirectory = URL(fileURLWithPath: cwd)
        let agentsNotice = AgentsContextService(
            fileManager: fileManager,
            globalAgentsDirectoryURL: globalAgentsDirectoryURL
        )
        .promptSection(workingDirectory: workingDirectory)
        // An organizer delegates by role, so it gets the role guidance instead
        // of the project roster: the runtime resolves the role per project.
        let delegatesByRole = selectedAgentRole?.delegatesByRole == true
        let delegatableSection: String? = locksModelToSession
            ? nil
            : {
                  let liveConfiguration = AgentDelegationCatalog.liveConfiguration(
                      fileManager: fileManager
                  )
                  // Only the profiles visible to this project are delegatable:
                  // the saved selection, or the system profiles when the
                  // project has none.
                  let projectProfiles = ProjectAgentSelectionStore.filter(
                      liveConfiguration.profiles,
                      workspaceRootURL: workingDirectory,
                      fileManager: fileManager
                  )
                  guard !projectProfiles.isEmpty else {
                      return SystemPromptBuilder.noProjectAgentsSection(
                          allowedToolNames: allowedToolNames
                      )
                  }
                  // The organizer lists the roles of those same profiles.
                  guard !delegatesByRole else {
                      return SystemPromptBuilder.roleDelegationSection(
                          allowedToolNames: allowedToolNames,
                          roles: AgentProfileRole.allCases.filter { role in
                              projectProfiles.contains { $0.role == role }
                          }
                      )
                  }
                  return SystemPromptBuilder.delegatableAgentsSection(
                      agents: projectProfiles,
                      allowedToolNames: allowedToolNames,
                      snapshot: liveConfiguration.catalog
                  )
              }()
        // The launch-folder listing is independent of the model lock and of
        // the tool grant: it only tells the organizer where its projects are.
        let launchFolderSection: String? = delegatesByRole
            ? SystemPromptBuilder.launchFolderProjectsSection(
                launchFolderProjects ?? LaunchFolderProjects.scan(
                    workingDirectory: workingDirectory,
                    listDirectory: listLaunchFolder
                )
            )
            : nil
        let agentsSection = [
            selectedAgentSection,
            agentsNotice,
            delegatableSection,
            launchFolderSection
        ]
            .compactMap { $0?.nilIfBlank }
            .joined(separator: "\n\n")
            .nilIfBlank
        return SystemPromptBuilder.standalonePromptSections(
            cwd: cwd,
            agentsSection: agentsSection,
            memorySection: memoryToolEnabled
                ? MemoryService.toolUsagePromptSection(
                    readOnly: AgentSessionComposition.memoryToolsAreReadOnly(allowedToolNames)
                )
                : nil,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            selectedSkillSection: selectedSkillSection,
            responseLanguageSection: responseLanguageSection,
            delegatesByRole: delegatesByRole,
            worktreeSection: worktreeSection
        )
    }
}
