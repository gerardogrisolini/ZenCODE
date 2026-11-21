//
//  TerminalWorkspaceToolAccessStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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

    /// Whether the folder of `workspaceURL` is already trusted, so
    /// ``ensureAccess(for:userDefaults:)`` would grant access without asking.
    /// It only reads `userDefaults`; it never asks.
    func hasAccess(
        for workspaceURL: URL,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        userDefaults.bool(forKey: terminalConsentKey(for: normalizedDirectoryURL(workspaceURL)))
    }

    private func authorizeWithTerminalConsentIfNeeded(
        for workspaceURL: URL,
        userDefaults: UserDefaults
    ) async -> Bool {
        let normalizedWorkspaceURL = normalizedDirectoryURL(workspaceURL)
        if hasAccess(for: workspaceURL, userDefaults: userDefaults) {
            return true
        }

        guard Self.requestTerminalConsent(for: normalizedWorkspaceURL) else {
            return false
        }
        userDefaults.set(true, forKey: terminalConsentKey(for: normalizedWorkspaceURL))
        return true
    }

    /// The `UserDefaults` key that records the trust of the folder of
    /// `workspaceURL`.
    func terminalConsentKey(for workspaceURL: URL) -> String {
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
