//
//  ZenDoctor.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ToolCore

/// Outcome of a single diagnostic check.
public enum ZenDoctorStatus: String, Sendable, Equatable {
    /// The check passed with no action required.
    case ok
    /// The check found a non-blocking condition worth surfacing.
    case warning
    /// The check found a blocking problem that prevents normal operation.
    case failure
    /// The check could not run in this environment (skipped by design).
    case info

    public var symbol: String {
        switch self {
        case .ok:
            return "✓"
        case .warning:
            return "!"
        case .failure:
            return "✗"
        case .info:
            return "·"
        }
    }

    public var label: String {
        switch self {
        case .ok:
            return "OK"
        case .warning:
            return "WARN"
        case .failure:
            return "FAIL"
        case .info:
            return "INFO"
        }
    }
}

/// A single, self-contained diagnostic result. All fields are guaranteed to be
/// secret-free: values are redacted with ``ZenSecretRedactor`` before storage.
public struct ZenDoctorCheck: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let status: ZenDoctorStatus
    /// A short, secret-free description of what was found.
    public let detail: String
    /// A concrete, actionable remedy. Empty when no action is needed.
    public let remedy: String?

    public init(
        id: String,
        title: String,
        status: ZenDoctorStatus,
        detail: String,
        remedy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = ZenSecretRedactor.redact(detail)
        self.remedy = remedy.map(ZenSecretRedactor.redact)
    }
}

/// A named group of related checks.
public struct ZenDoctorSection: Sendable, Equatable {
    public let title: String
    public let checks: [ZenDoctorCheck]

    public init(title: String, checks: [ZenDoctorCheck]) {
        self.title = title
        self.checks = checks
    }
}

/// The full diagnostic report.
public struct ZenDoctorReport: Sendable, Equatable {
    public let sections: [ZenDoctorSection]

    public init(sections: [ZenDoctorSection]) {
        self.sections = sections
    }

    public var allChecks: [ZenDoctorCheck] {
        sections.flatMap(\.checks)
    }

    public var hasFailure: Bool {
        allChecks.contains { $0.status == .failure }
    }

    public var hasWarning: Bool {
        allChecks.contains { $0.status == .warning }
    }

    /// Process exit code: non-zero only when a blocking failure was found so the
    /// command is scriptable, while warnings alone stay successful.
    public var exitCode: Int32 {
        hasFailure ? 1 : 0
    }
}

/// Non-interactive, read-only environment/configuration/permissions diagnostics.
///
/// `ZenDoctor` never writes files, never starts setup, never performs network
/// access, and never reveals secrets. It inspects the support directory,
/// settings, agents, and permissions manifests and the runtime environment,
/// reporting actionable remedies. It is safe to run in any mode.
public enum ZenDoctor {
    /// Builds a diagnostic report without mutating any state.
    ///
    /// `cronToolchain` overrides the probed `crontab`/`sendmail` locations; when
    /// `nil`, the system tools are located with ``ZenCronToolchain/locate(fileManager:)``.
    public static func runReport(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL? = nil,
        cronToolchain: ZenCronToolchain? = nil
    ) -> ZenDoctorReport {
        let paths = manifestPaths(
            fileManager: fileManager,
            supportDirectory: supportDirectory
        )
        let toolchain = cronToolchain ?? ZenCronToolchain.locate(fileManager: fileManager)
        return ZenDoctorReport(sections: [
            environmentSection(environment: environment),
            supportFilesSection(paths: paths, fileManager: fileManager),
            configurationSection(paths: paths, fileManager: fileManager),
            permissionsSection(paths: paths, fileManager: fileManager),
            diagnosticsSection(environment: environment),
            schedulingSection(toolchain: toolchain)
        ])
    }

    /// Paths consulted by the doctor. Constructing them performs no filesystem
    /// access, so the report can inspect an unconfigured installation without
    /// creating its support directory.
    struct ManifestPaths {
        let supportDirectory: URL
        let settings: URL
        let agents: URL
        let permissions: URL
    }

    // MARK: - File privacy

    static func filePrivacyCheck(
        id: String,
        title: String,
        url: URL,
        fileManager: FileManager
    ) -> ZenDoctorCheck {
        #if canImport(Darwin) || canImport(Glibc)
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let posixPermissions = attributes[.posixPermissions] as? NSNumber else {
            return ZenDoctorCheck(
                id: id,
                title: title,
                status: .info,
                detail: "Could not read file permissions for \(url.lastPathComponent)."
            )
        }
        let mode = posixPermissions.uint16Value
        let groupOrOtherAccessible = (mode & 0o077) != 0
        return ZenDoctorCheck(
            id: id,
            title: title,
            status: groupOrOtherAccessible ? .warning : .ok,
            detail: groupOrOtherAccessible
                ? "\(url.lastPathComponent) is accessible by group/other (mode \(String(mode, radix: 8)))."
                : "\(url.lastPathComponent) is restricted to the owner.",
            remedy: groupOrOtherAccessible
                ? "Run chmod 600 on the \(url.lastPathComponent) file to restrict it to your user."
                : nil
        )
        #else
        return ZenDoctorCheck(
            id: id,
            title: title,
            status: .info,
            detail: "File permission checks are not available on this platform."
        )
        #endif
    }

    // MARK: - Read-only manifest access

    /// Outcome of a read-only manifest decode. Decoding happens directly from the
    /// raw file bytes so that no manifest store is consulted: the stores call
    /// `SensitiveFilePermissions.hardenExistingFile` on load, which would mutate
    /// file permissions and break the doctor's read-only guarantee.
    enum ManifestReadOutcome<T> {
        case value(T)
        case missing
        case invalid
    }

    private static func readManifest<T: Decodable>(
        at url: URL,
        fileManager: FileManager,
        validate: (T) -> Bool
    ) -> ManifestReadOutcome<T> {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(T.self, from: data),
              validate(decoded) else {
            return .invalid
        }
        return .value(decoded)
    }

    static func readSettingsManifest(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestReadOutcome<AgentSettingsManifest> {
        readManifest(at: url, fileManager: fileManager) { manifest in
            manifest.version >= AgentSettingsManifest.minimumSupportedVersion
                && manifest.version <= AgentSettingsManifest.currentVersion
        }
    }

    static func readPermissionsManifest(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestReadOutcome<AgentPermissionsManifest> {
        readManifest(at: url, fileManager: fileManager) { manifest in
            manifest.version >= AgentPermissionsManifest.minimumSupportedVersion
                && manifest.version <= AgentPermissionsManifest.currentVersion
        }
    }

    static func readAgentProfiles(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestReadOutcome<[AgentProfile]> {
        let outcome: ManifestReadOutcome<AgentProfileManifest> = readManifest(
            at: url,
            fileManager: fileManager
        ) { manifest in
            manifest.version == AgentProfileManifest.currentVersion
                && !manifest.agents.isEmpty
        }
        switch outcome {
        case let .value(manifest):
            return .value(manifest.agents)
        case .missing:
            return .missing
        case .invalid:
            return .invalid
        }
    }

    // MARK: - Helpers

    private static func manifestPaths(
        fileManager: FileManager,
        supportDirectory: URL?
    ) -> ManifestPaths {
        let supportDirectory = supportDirectory?.standardizedFileURL
            ?? AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
        return ManifestPaths(
            supportDirectory: supportDirectory,
            settings: supportDirectory.appendingPathComponent("settings.json"),
            agents: supportDirectory.appendingPathComponent("agents.json"),
            permissions: supportDirectory.appendingPathComponent("permissions.json")
        )
    }

    static func directoryExists(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func platformDescription() -> String {
        #if os(macOS)
        let osName = "macOS"
        #elseif os(Linux)
        let osName = isWindowsSubsystemForLinux() ? "Linux (WSL)" : "Linux"
        #else
        let osName = "Unknown"
        #endif
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        return "\(osName) — \(version)"
    }

    #if os(Linux)
    static func isWindowsSubsystemForLinux() -> Bool {
        let markers = ["/proc/sys/kernel/osrelease", "/proc/version"]
        for marker in markers {
            if let contents = try? String(contentsOfFile: marker, encoding: .utf8) {
                let normalized = contents.lowercased()
                if normalized.contains("microsoft") || normalized.contains("wsl") {
                    return true
                }
            }
        }
        return ProcessInfo.processInfo.environment["WSL_DISTRO_NAME"]?.nilIfBlank != nil
    }
    #endif
}
