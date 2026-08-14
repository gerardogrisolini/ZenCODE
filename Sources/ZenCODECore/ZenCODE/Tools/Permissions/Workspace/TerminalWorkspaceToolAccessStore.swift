//
//  TerminalWorkspaceToolAccessStore.swift
//  ZenCODE
//

import Foundation

#if os(macOS)
public actor TerminalWorkspaceToolAccessStore {
    public static let shared = TerminalWorkspaceToolAccessStore()

    public func ensureAccess(
        for workspaceURL: URL,
        userDefaults: UserDefaults = .standard
    ) async -> Bool {
        await authorizeWithTerminalConsentIfNeeded(
            for: workspaceURL,
            userDefaults: userDefaults
        )
    }

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
}
#endif
