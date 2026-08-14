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
    /// Explicit marker for helper executables built exclusively to exercise
    /// test behaviour outside the XCTest process.
    public static let testHarnessArgument = "--zencode-test-harness"
    private static let supportDirectoryName = ".zencode"
    private static let supportDirectoryOverride = SupportDirectoryOverride()
    private static let testHarnessSandbox = TestHarnessSandbox()
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

    /// The real `~/.zencode`, ignoring every override.
    ///
    /// This is the *definition* of the default location, not the location a
    /// caller should write to: use ``appSupportDirectoryURL(fileManager:)`` for
    /// that, so overrides and the test-harness guard below are honoured.
    public static func defaultSupportDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        UserHomeDirectory.current(fileManager: fileManager)
            .appendingPathComponent(supportDirectoryName, isDirectory: true)
            .standardizedFileURL
    }

    /// Whether this process is a test harness.
    ///
    /// Detected from several independent signals because there is no single
    /// portable one: Xcode sets `XCTest*` variables, `swift test` runs the
    /// bundle through `swiftpm-testing-helper` (or `xctest`) and carries the
    /// `.xctest` bundle path in its arguments rather than as its own executable,
    /// and a directly launched bundle shows up in `Bundle.main`. Over-detection
    /// is harmless here (a redirected support directory), while under-detection
    /// only restores the previous behaviour, so the checks are deliberately
    /// broad.
    public static var isRunningUnderTestHarness: Bool {
        let processInfo = ProcessInfo.processInfo
        return isRunningUnderTestHarness(
            processName: processInfo.processName,
            arguments: processInfo.arguments,
            environment: processInfo.environment,
            bundlePath: Bundle.main.bundlePath
        )
    }

    /// Pure detection seam so the standalone-helper marker is tested without
    /// relying on this XCTest process's ambient overrides.
    static func isRunningUnderTestHarness(
        processName: String,
        arguments: [String],
        environment: [String: String],
        bundlePath: String
    ) -> Bool {
        let testEnvironmentKeys = [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCTestSessionIdentifier",
            "SWIFT_TESTING_ENABLED"
        ]
        if testEnvironmentKeys.contains(where: { environment[$0] != nil }) {
            return true
        }
        let testHarnessProcessNames: Set<String> = [
            "xctest",
            "swiftpm-testing-helper",
            "swiftpm-xctest-helper"
        ]
        if testHarnessProcessNames.contains(processName) {
            return true
        }
        // Some test helpers are standalone executable products, so they do
        // not inherit XCTest's process name, bundle path, or environment.
        // They opt in explicitly rather than relying on those parent signals.
        if arguments.contains(testHarnessArgument) {
            return true
        }
        // Substring, not suffix: the bundle is normally passed as a path *into*
        // the bundle (`…/Tests.xctest/Contents/MacOS/Tests`), so a suffix check
        // misses every SwiftPM invocation on macOS.
        if arguments.contains(where: { $0.contains(".xctest") }) {
            return true
        }
        return bundlePath.contains(".xctest")
    }

    /// Per-process throwaway support directory used by test harnesses.
    ///
    /// Central and conservative counterpart to the per-test task-local
    /// override: a suite that forgets to scope itself — or a code path that
    /// escapes the scope by hopping onto a detached task — writes here instead
    /// of into the developer's real `~/.zencode`. It is created lazily and
    /// cached, so every unscoped read in one test process agrees on one
    /// location, and it is left on disk under the system temporary directory
    /// rather than deleted, because tests may still be reading it when a suite
    /// ends.
    public static func testHarnessSandboxURL() -> URL? {
        guard isRunningUnderTestHarness else {
            return nil
        }
        return testHarnessSandbox.url()
    }

    private static func configuredSupportDirectoryURL() -> URL? {
        if let scopedSupportDirectoryURL {
            return scopedSupportDirectoryURL
        }
        if let url = supportDirectoryOverride.url() {
            return url
        }
        guard let rawValue = normalizedPath(ProcessInfo.processInfo.environment[supportDirectoryEnvironmentKey]) else {
            // Nothing configured at all. Under a test harness that would mean
            // the developer's real support directory, so it is redirected.
            return testHarnessSandboxURL()
        }
        let configured = URL(fileURLWithPath: rawValue, isDirectory: true)
            .standardizedFileURL
        // An ambient `ZENCODE_SUPPORT_DIRECTORY` is honoured under test as
        // well — it is explicit operator intent — unless it names the real
        // `~/.zencode`, which is the one value a test run must never write to.
        guard configured == defaultSupportDirectoryURL(),
              let sandbox = testHarnessSandboxURL() else {
            return configured
        }
        return sandbox
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

/// Lazily resolved, process-stable sandbox for test harnesses.
///
/// The path embeds the process id and one UUID so two concurrent or successive
/// test processes never share state, while every call inside one process
/// returns the same directory.
private final class TestHarnessSandbox: Sendable {
    private let value = Mutex<URL?>(nil)

    func url() -> URL {
        value.withLock { value in
            if let value {
                return value
            }
            let resolved = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "zencode-test-support-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                    isDirectory: true
                )
                .standardizedFileURL
            value = resolved
            return resolved
        }
    }
}
