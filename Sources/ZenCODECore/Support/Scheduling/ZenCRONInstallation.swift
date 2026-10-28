//
//  ZenCRONInstallation.swift
//  ZenCODE
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Where `ZenCRON` lives and how it is installed, read and replaced.
///
/// `ZenCRON` is the stable host that cron starts for every scheduled prompt
/// written by `/cron add`: on macOS the privacy permissions of a cron job go to
/// the first program cron launches, so that program must not change from one
/// ZenCODE update to the next. It is a standalone SwiftPM package
/// (`Sources/ZenCRON` in the source checkout) built by `/setup` and installed,
/// without sudo, at `<support directory>/bin/ZenCRON`.
///
/// Replacement policy (`decision`): on macOS an installed ZenCRON is kept as
/// long as its `--zencron-version` equals the freshly built one, because
/// replacing the binary makes macOS ask for the permissions again. On Linux it
/// is always replaced: the Swift runtime is linked dynamically to the toolchain,
/// so an old ZenCRON may no longer start after a toolchain change.
enum ZenCRONInstallation {
    /// File name of the installed host, and the SwiftPM product that builds it.
    static let executableName = "ZenCRON"

    /// Package directory relative to the root of the ZenCODE source checkout.
    static let packageRelativePath = "Sources/ZenCRON"

    /// Argument that makes ZenCRON print its version and exit.
    static let versionArgument = "--zencron-version"

    /// How long a version query may take before the executable is considered
    /// not to start.
    static let defaultVersionTimeout: TimeInterval = 10

    /// Directory of the support directory that holds installed executables.
    static let binDirectoryName = "bin"

    /// Directory of the support directory that holds the stable working copy
    /// of the package, so that builds are incremental.
    static let workingDirectoryName = "zencron"

    // MARK: - Locations

    /// `<support directory>/bin/ZenCRON`.
    static func installedExecutableURL(
        supportDirectory: URL = ZenFileService.supportDirectoryURL()
    ) -> URL {
        supportDirectory
            .appendingPathComponent(binDirectoryName, isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    /// `<support directory>/zencron/package`: the copy of the package that is
    /// built. Its `.build` directory survives from one build to the next.
    static func workingCopyURL(
        supportDirectory: URL = ZenFileService.supportDirectoryURL()
    ) -> URL {
        supportDirectory
            .appendingPathComponent(workingDirectoryName, isDirectory: true)
            .appendingPathComponent("package", isDirectory: true)
    }

    /// `<package>/.build/release/ZenCRON`: where `swift build -c release`
    /// leaves the executable.
    static func builtExecutableURL(packageDirectory: URL) -> URL {
        packageDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("release", isDirectory: true)
            .appendingPathComponent(executableName, isDirectory: false)
    }

    // MARK: - Version

    /// Why a ZenCRON executable did not report its version. The description is
    /// a clause that completes "ZenCRON at <path> does not start (…)".
    enum VersionError: LocalizedError, Equatable {
        case notExecutable
        case launchFailed(String)
        case timedOut(seconds: Int)
        case exitStatus(Int32, stderr: String)
        case noOutput
        case multipleLines
        case unexpectedOutput(String)

        var errorDescription: String? {
            switch self {
            case .notExecutable:
                return "it is not executable"
            case let .launchFailed(reason):
                return "it could not be launched: \(reason)"
            case let .timedOut(seconds):
                return "it did not answer \(versionArgument) within \(seconds) seconds"
            case let .exitStatus(status, stderr):
                let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty
                    ? "it exited with status \(status)"
                    : "it exited with status \(status): \(detail)"
            case .noOutput:
                return "it printed no version"
            case .multipleLines:
                return "it printed more than one line instead of a single version line"
            case let .unexpectedOutput(output):
                return "it printed '\(output)' instead of '\(executableName) <number>'"
            }
        }
    }

    /// The single line `ZenCRON <N>` that `--zencron-version` must print.
    ///
    /// The line is returned without its line break; anything else (no output,
    /// several lines, other text) is an error, so a binary that is not a
    /// ZenCRON never passes for one.
    static func parseVersion(_ output: String) throws -> String {
        var text = output
        // "\r\n" is a single Character: drop one trailing line break, whichever.
        if let last = text.last, last == "\n" || last == "\r\n" {
            text.removeLast()
        }
        guard !text.isEmpty else { throw VersionError.noOutput }
        guard !text.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw VersionError.multipleLines
        }
        let prefix = "\(executableName) "
        let number = text.dropFirst(prefix.count)
        let isVersionLine = text.hasPrefix(prefix)
            && !number.isEmpty
            && number.unicodeScalars.allSatisfy { ("0"..."9").contains($0) }
        guard isVersionLine else { throw VersionError.unexpectedOutput(text) }
        return text
    }

    /// Turns the outcome of a finished `--zencron-version` run into the version
    /// line. Pure, so every outcome is testable without a process.
    static func interpretVersionResult(
        exitCode: Int32,
        timedOut: Bool,
        stdout: String,
        stderr: String,
        timeout: TimeInterval = defaultVersionTimeout
    ) throws -> String {
        if timedOut {
            throw VersionError.timedOut(seconds: Int(timeout.rounded(.up)))
        }
        guard exitCode == 0 else {
            throw VersionError.exitStatus(exitCode, stderr: stderr)
        }
        return try parseVersion(stdout)
    }

    /// Runs `<executable> --zencron-version` with standard input on `/dev/null`
    /// and returns its version line (`ZenCRON <N>`).
    static func version(
        ofExecutableAt url: URL,
        timeout: TimeInterval = defaultVersionTimeout
    ) async throws -> String {
        let result: AsyncProcessResult
        do {
            // No stdin data: the runner gives the child /dev/null.
            result = try await AsyncProcessRunner.run(
                executableURL: url,
                arguments: [versionArgument],
                timeout: timeout,
                maximumOutputBytesPerStream: 4 * 1_024
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw VersionError.launchFailed(error.localizedDescription)
        }
        return try interpretVersionResult(
            exitCode: result.exitCode,
            timedOut: result.timedOut,
            stdout: result.stdout,
            stderr: result.stderr,
            timeout: timeout
        )
    }

    // MARK: - Installed host

    /// A ZenCRON that exists, is executable and answered `--zencron-version`.
    struct InstalledExecutable: Equatable, Sendable {
        /// Absolute path, as written on crontab lines.
        let path: String
        /// The `ZenCRON <N>` line.
        let version: String
    }

    /// The installed ZenCRON, checked the way `/cron add` needs it: present,
    /// executable and answering `--zencron-version`.
    ///
    /// - Throws: `ZenCrontabError.zenCRONNotInstalled` when there is no file,
    ///   `ZenCrontabError.zenCRONDoesNotStart` when there is one that does not
    ///   report a version.
    static func checkedInstalledExecutable(
        supportDirectory: URL = ZenFileService.supportDirectoryURL(),
        fileManager: FileManager = .default,
        timeout: TimeInterval = defaultVersionTimeout
    ) async throws -> InstalledExecutable {
        let url = installedExecutableURL(supportDirectory: supportDirectory)
        guard fileManager.fileExists(atPath: url.path) else {
            throw ZenCrontabError.zenCRONNotInstalled(path: url.path)
        }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw ZenCrontabError.zenCRONDoesNotStart(
                path: url.path,
                reason: VersionError.notExecutable.localizedDescription
            )
        }
        do {
            let version = try await version(ofExecutableAt: url, timeout: timeout)
            return InstalledExecutable(path: url.path, version: version)
        } catch let error as VersionError {
            throw ZenCrontabError.zenCRONDoesNotStart(
                path: url.path,
                reason: error.localizedDescription
            )
        }
    }

    // MARK: - Replacement policy

    /// Platforms with a different replacement policy.
    enum Platform: Equatable, Sendable {
        case macOS
        case linux

        static var current: Platform {
            #if os(macOS)
            return .macOS
            #else
            return .linux
            #endif
        }
    }

    /// What to do with an installed ZenCRON once a new one is built.
    enum Decision: Equatable, Sendable {
        /// Leave the installed executable untouched.
        case keep
        /// Replace it (or create it) with the new build.
        case install
    }

    /// Whether the newly built ZenCRON must replace the installed one.
    ///
    /// - macOS: keep when the installed version equals the built one; install
    ///   when it is missing, unreadable (`nil`) or different, because replacing
    ///   the binary makes macOS ask for the privacy permissions again.
    /// - Linux: always install, because the Swift runtime is linked
    ///   dynamically to the toolchain and an old ZenCRON may no longer start.
    static func decision(
        installedVersion: String?,
        builtVersion: String,
        platform: Platform = .current
    ) -> Decision {
        switch platform {
        case .macOS:
            return installedVersion == builtVersion ? .keep : .install
        case .linux:
            return .install
        }
    }

    // MARK: - Installation

    enum InstallError: LocalizedError, Equatable {
        case failed(path: String, reason: String)

        var errorDescription: String? {
            switch self {
            case let .failed(path, reason):
                return "Could not install ZenCRON at \(path): \(reason)"
            }
        }
    }

    /// Copies `builtExecutable` to `<support directory>/bin/ZenCRON` atomically
    /// and returns the installed URL.
    ///
    /// The bytes are copied as they are: no strip and no other change, so the
    /// signature of the build stays valid. The copy goes to a hidden temporary
    /// file in the `bin` directory (created with 0755 when missing), gets mode
    /// 0755, and replaces the target with a single `rename`, so a running
    /// ZenCRON or a cron job never sees a partial file. The temporary file is
    /// removed on every failure.
    @discardableResult
    static func install(
        builtExecutable: URL,
        supportDirectory: URL = ZenFileService.supportDirectoryURL(),
        fileManager: FileManager = .default
    ) throws -> URL {
        let target = installedExecutableURL(supportDirectory: supportDirectory)
        let binDirectory = target.deletingLastPathComponent()
        func failure(_ reason: String) -> InstallError {
            .failed(path: target.path, reason: reason)
        }

        do {
            if !fileManager.fileExists(atPath: binDirectory.path) {
                try fileManager.createDirectory(
                    at: binDirectory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o755]
                )
                try fileManager.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: binDirectory.path
                )
            }
        } catch {
            throw failure("the directory \(binDirectory.path) cannot be created: \(error.localizedDescription)")
        }

        let temporary = binDirectory.appendingPathComponent(
            ".\(executableName).install-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var didPublish = false
        defer {
            if !didPublish {
                try? fileManager.removeItem(at: temporary)
            }
        }

        do {
            // A symbolic link would be copied as a link, not as the executable.
            try fileManager.copyItem(
                at: builtExecutable.resolvingSymlinksInPath(),
                to: temporary
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: temporary.path
            )
        } catch {
            throw failure(error.localizedDescription)
        }

        guard rename(temporary.path, target.path) == 0 else {
            throw failure(String(cString: strerror(errno)))
        }
        didPublish = true
        return target
    }
}
