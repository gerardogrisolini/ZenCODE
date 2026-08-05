//
//  AppStorageDirectory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization

public enum AppStorageDirectory {
    public static let supportDirectoryEnvironmentKey = "ZENCODE_SUPPORT_DIRECTORY"
    private static let supportDirectoryName = ".zencode"
    private static let supportDirectoryOverride = SupportDirectoryOverride()
    @TaskLocal private static var scopedSupportDirectoryURL: URL?

    public static func configureSupportDirectoryURL(_ url: URL?) {
        supportDirectoryOverride.set(url?.standardizedFileURL)
    }

    /// Lexically scopes a support directory to the current structured task.
    /// This avoids process-global override races in concurrent embedders/tests
    /// while preserving `configureSupportDirectoryURL` for legacy callers.
    public static func withSupportDirectoryURL<T>(
        _ url: URL?,
        operation: () throws -> T
    ) rethrows -> T {
        try $scopedSupportDirectoryURL.withValue(
            url?.standardizedFileURL,
            operation: operation
        )
    }

    public static func withSupportDirectoryURL<T>(
        _ url: URL?,
        operation: () async throws -> T
    ) async rethrows -> T {
        try await $scopedSupportDirectoryURL.withValue(
            url?.standardizedFileURL
        ) {
            try await operation()
        }
    }

    public static func appSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        if let configuredDirectoryURL = configuredSupportDirectoryURL() {
            return configuredDirectoryURL
        }
        return defaultSupportDirectoryURL(fileManager: fileManager)
    }

    public static func defaultSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        UserHomeDirectory.current(fileManager: fileManager)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    private static func configuredSupportDirectoryURL() -> URL? {
        if let scopedSupportDirectoryURL {
            return scopedSupportDirectoryURL
        }
        if let url = supportDirectoryOverride.url() {
            return url
        }
        guard let rawValue = normalizedPath(ProcessInfo.processInfo.environment[supportDirectoryEnvironmentKey]) else {
            return nil
        }
        return URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
    }

    private static func normalizedPath(_ value: String?) -> String? {
        let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedValue.isEmpty ? nil : trimmedValue
    }
}

private final class SupportDirectoryOverride: Sendable {
    private let value = Mutex<URL?>(nil)

    func set(_ url: URL?) {
        value.withLock { value in
            value = url
        }
    }

    func url() -> URL? {
        value.withLock { value in
            value
        }
    }
}
