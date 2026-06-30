//
//  LocalExecPermissionAuthorizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

#if os(macOS)
import AppKit
#endif

public actor LocalExecPermissionAuthorizer {
    private enum PermissionDecision: Sendable {
        case allowOnce
        case allowAlways
        case deny
    }

    private var alwaysAllowedKeys = Set<String>()
    private var didLoadPersistedAllowedCommands = false

    public init() {}

    public func authorize(_ request: AgentToolAuthorizationRequest) async -> Bool {
        guard request.toolName == "local.exec" else {
            return true
        }

        #if !os(macOS)
        return true
        #else
        loadPersistedAllowedCommandsIfNeeded()
        let cacheKey = permissionCacheKey(for: request)
        if alwaysAllowedKeys.contains(cacheKey) {
            return true
        }

        guard let decision = await presentDialog(for: request) else {
            return false
        }

        switch decision {
        case .allowOnce:
            return true
        case .allowAlways:
            alwaysAllowedKeys.insert(cacheKey)
            persistAllowedCommand(for: request)
            return true
        case .deny:
            return false
        }
        #endif
    }

    static func commandPermissionIdentity(for command: String) -> String? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = trimmedCommand
            .split(whereSeparator: \.isWhitespace)
            .first else {
            return nil
        }
        return String(firstWord)
    }

    static func persistedCommandPermissionIdentity(for command: String) -> String? {
        commandPermissionIdentity(for: command)
    }

    static func isCommandPersistentlyAllowed(
        _ command: String,
        permissions: AgentPermissionsManifest? = persistedPermissions()
    ) -> Bool {
        guard let commandIdentity = persistedCommandPermissionIdentity(for: command),
              let permissions else {
            return false
        }
        return permissions.containsLocalExecAllowedCommand(commandIdentity)
    }

    static func persistAllowedCommand(_ command: String) {
        guard let commandIdentity = persistedCommandPermissionIdentity(for: command) else {
            return
        }
        persistAllowedCommandIdentity(commandIdentity)
    }

    private func permissionCacheKey(for request: AgentToolAuthorizationRequest) -> String {
        [
            request.toolName,
            Self.persistedCommandPermissionIdentity(for: request.command) ?? request.command
        ].joined(separator: "\u{1f}")
    }

    private func loadPersistedAllowedCommandsIfNeeded() {
        guard !didLoadPersistedAllowedCommands else {
            return
        }
        didLoadPersistedAllowedCommands = true
        guard let permissions = Self.persistedPermissions() else {
            return
        }
        alwaysAllowedKeys.formUnion(
            permissions.localExecAllowedCommands.map { "local.exec\u{1f}\($0)" }
        )
    }

    private func persistAllowedCommand(for request: AgentToolAuthorizationRequest) {
        guard let commandIdentity = Self.persistedCommandPermissionIdentity(for: request.command) else {
            return
        }
        Self.persistAllowedCommandIdentity(commandIdentity)
    }

    private static func persistAllowedCommandIdentity(_ commandIdentity: String) {
        let permissions = persistedPermissions()
            ?? AgentPermissionsManifest()
        guard !permissions.containsLocalExecAllowedCommand(commandIdentity) else {
            return
        }
        do {
            try AgentPermissionsManifestStore.save(
                permissions.appendingLocalExecAllowedCommand(commandIdentity)
            )
        } catch {
            return
        }
    }

    private static func persistedPermissions() -> AgentPermissionsManifest? {
        let permissions = AgentPermissionsManifestStore.load()
        let legacyCommands = AgentSettingsManifestStore.load()?.localExecAllowedCommands ?? []
        guard permissions != nil || !legacyCommands.isEmpty else {
            return nil
        }

        let migrated = AgentPermissionsManifest(
            localExecAllowedCommands: (permissions?.localExecAllowedCommands ?? []) + legacyCommands
        )
        if migrated != permissions {
            try? AgentPermissionsManifestStore.save(migrated)
        }
        return migrated
    }

    private func presentDialog(
        for request: AgentToolAuthorizationRequest
    ) async -> PermissionDecision? {
        #if os(macOS)
        await Self.presentMacDialog(for: request)
        #else
        nil
        #endif
    }

    #if os(macOS)
    private static func presentMacDialog(
        for request: AgentToolAuthorizationRequest
    ) async -> PermissionDecision? {
        let script = """
        on run argv
            set dialogTitle to item 1 of argv
            set workingDirectory to item 2 of argv
            set shellCommand to item 3 of argv
            set dialogText to "A local tool wants to run a command with access to the workspace." & return & return & "Directory:" & return & workingDirectory & return & return & "Command:" & return & shellCommand & return & return & "If you continue, the command may read or modify files, run scripts, and launch other local processes."
            set dialogResult to display dialog dialogText buttons {"Cancel", "Always", "Run"} default button "Run" cancel button "Cancel" with title dialogTitle with icon caution
            return button returned of dialogResult
        end run
        """

        let result: AsyncProcessResult
        do {
            result = try await AsyncProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: [
                    "-e", script,
                    request.title,
                    request.workingDirectory,
                    request.command
                ],
                timeout: nil
            )
        } catch {
            return nil
        }

        guard result.exitCode == 0 else {
            return .deny
        }

        switch result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Run":
            return .allowOnce
        case "Always":
            return .allowAlways
        case "Cancel":
            return .deny
        default:
            return nil
        }
    }
    #endif
}

#if os(macOS)
public actor TerminalWorkspaceToolAccessStore {
    public static let shared = TerminalWorkspaceToolAccessStore()

    private let bookmarkPrefix = "workspaceToolAccessBookmark:"
    private var activeURLs: [String: URL] = [:]

    public func activatePersistedAccess(
        for workspaceURL: URL,
        userDefaults: UserDefaults = .standard
    ) -> URL? {
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        let key = bookmarkKey(for: normalizedWorkspaceURL)

        if let activeURL = activeURLs[key] {
            return activeURL
        }

        guard let bookmarkData = userDefaults.data(forKey: key) else {
            return nil
        }

        var isStale = false
        guard let resolvedURL = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            userDefaults.removeObject(forKey: key)
            return nil
        }

        let normalizedResolvedURL = normalizedDirectoryURL(resolvedURL)
        guard coversWorkspace(
            authorizedDirectoryURL: normalizedResolvedURL,
            workspaceURL: normalizedWorkspaceURL
        ) else {
            userDefaults.removeObject(forKey: key)
            return nil
        }

        _ = normalizedResolvedURL.startAccessingSecurityScopedResource()
        activeURLs[key] = normalizedResolvedURL

        if isStale {
            try? persistBookmark(
                for: normalizedResolvedURL,
                key: key,
                userDefaults: userDefaults
            )
        }

        return normalizedResolvedURL
    }

    public func ensureAccess(
        for workspaceURL: URL,
        userDefaults: UserDefaults = .standard
    ) async -> Bool {
        #if SWIFTPM_NON_SANDBOX_TUI
        return await authorizeWithTerminalConsentIfNeeded(
            for: workspaceURL,
            userDefaults: userDefaults
        )
        #else
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        return activatePersistedAccess(
            for: normalizedWorkspaceURL,
            userDefaults: userDefaults
        ) != nil
        #endif
    }

    public func authorizeWithPickerIfNeeded(
        for workspaceURL: URL,
        userDefaults: UserDefaults = .standard
    ) async -> Bool {
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        if activatePersistedAccess(
            for: normalizedWorkspaceURL,
            userDefaults: userDefaults
        ) != nil {
            return true
        }

        guard let selectedURL = await Self.requestAccess(for: normalizedWorkspaceURL) else {
            return false
        }

        do {
            try saveAccess(
                for: selectedURL,
                workspaceURL: normalizedWorkspaceURL,
                userDefaults: userDefaults
            )
            return true
        } catch {
            return false
        }
    }

    #if SWIFTPM_NON_SANDBOX_TUI
    private func authorizeWithTerminalConsentIfNeeded(
        for workspaceURL: URL,
        userDefaults: UserDefaults
    ) async -> Bool {
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        let key = terminalConsentKey(for: normalizedWorkspaceURL)
        if userDefaults.bool(forKey: key) {
            return true
        }

        guard Self.requestTerminalConsent(for: normalizedWorkspaceURL) else {
            return false
        }
        userDefaults.set(true, forKey: key)
        return true
    }

    private func terminalConsentKey(for workspaceURL: URL) -> String {
        "workspaceToolAccessConsent:" + normalizedDirectoryURL(workspaceURL).path
    }

    private static func requestTerminalConsent(for workspaceURL: URL) -> Bool {
        let prompt =
            """
            ZenCODE requires permission to read, edit, and execute files here.

            Directory:
            \(workspaceURL.path)

            """
            + "Trust this folder? [Y/n]: "
        let answer = TerminalInteractiveLineReader().readSingleKey(
            prompt: prompt
        )
        guard let answer else {
            return false
        }
        return terminalConsentAllowsAccess(answer)
    }

    static func terminalConsentAllowsAccess(_ answer: String) -> Bool {
        switch answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "y", "yes":
            return true
        default:
            return false
        }
    }
    #endif

    public func saveAccess(
        for selectedURL: URL,
        workspaceURL: URL,
        userDefaults: UserDefaults
    ) throws {
        let normalizedSelectedURL = normalizedDirectoryURL(selectedURL)
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        guard coversWorkspace(
            authorizedDirectoryURL: normalizedSelectedURL,
            workspaceURL: normalizedWorkspaceURL
        ) else {
            throw TerminalWorkspaceToolAccessError.invalidAuthorizedDirectory(
                normalizedWorkspaceURL.path
            )
        }

        let key = bookmarkKey(for: normalizedWorkspaceURL)
        if let activeURL = activeURLs[key],
           activeURL.path != normalizedSelectedURL.path {
            activeURL.stopAccessingSecurityScopedResource()
            activeURLs.removeValue(forKey: key)
        }

        let didStartAccessing = normalizedSelectedURL.startAccessingSecurityScopedResource()
        do {
            try persistBookmark(
                for: normalizedSelectedURL,
                key: key,
                userDefaults: userDefaults
            )
            activeURLs[key] = normalizedSelectedURL
        } catch {
            if didStartAccessing {
                normalizedSelectedURL.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    public func bookmarkKey(
        for workspaceURL: URL
    ) -> String {
        bookmarkPrefix + normalizedDirectoryURL(workspaceURL).path
    }

    public func normalizedDirectoryURL(
        _ url: URL
    ) -> URL {
        let standardizedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: standardizedURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue {
            return standardizedURL
        }
        return standardizedURL.hasDirectoryPath
            ? standardizedURL
            : standardizedURL.deletingLastPathComponent()
    }

    public func coversWorkspace(
        authorizedDirectoryURL: URL,
        workspaceURL: URL
    ) -> Bool {
        let authorizedPath = authorizedDirectoryURL.path.hasSuffix("/")
            ? authorizedDirectoryURL.path
            : authorizedDirectoryURL.path + "/"
        let workspacePath = workspaceURL.path
        return workspacePath == authorizedDirectoryURL.path
            || workspacePath.hasPrefix(authorizedPath)
    }

    private func persistBookmark(
        for directoryURL: URL,
        key: String,
        userDefaults: UserDefaults
    ) throws {
        let bookmarkData = try directoryURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        userDefaults.set(bookmarkData, forKey: key)
    }

    @MainActor
    private static func requestAccess(for workspaceURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Authorize ACP Workspace"
        panel.message = "Authorize the folder that the ACP client passed to ZenCODE."
        panel.prompt = "Authorize"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true

        let parentURL = workspaceURL.deletingLastPathComponent()
        if parentURL.path.isEmpty || parentURL.path == workspaceURL.path {
            panel.directoryURL = workspaceURL
        } else {
            panel.directoryURL = parentURL
            panel.nameFieldStringValue = workspaceURL.lastPathComponent
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK else {
            return nil
        }
        return panel.url?.standardizedFileURL
    }
}

public enum TerminalWorkspaceToolAccessError: LocalizedError {
    case invalidAuthorizedDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidAuthorizedDirectory(workspacePath):
            return "Select the workspace folder \(workspacePath) or one of its parent folders to authorize local coding tools."
        }
    }
}
#endif
