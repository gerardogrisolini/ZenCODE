//
//  TerminalWorkspaceToolAccessStore.swift
//  ZenCODE
//

import Foundation

#if os(macOS)
import AppKit
#endif

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
