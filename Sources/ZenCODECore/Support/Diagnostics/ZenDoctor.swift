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
import ZenPackageMetadata

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
    public static func runReport(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL? = nil
    ) -> ZenDoctorReport {
        let paths = manifestPaths(
            fileManager: fileManager,
            supportDirectory: supportDirectory
        )
        return ZenDoctorReport(sections: [
            environmentSection(environment: environment),
            supportFilesSection(paths: paths, fileManager: fileManager),
            configurationSection(paths: paths, fileManager: fileManager),
            permissionsSection(paths: paths, fileManager: fileManager),
            diagnosticsSection(environment: environment)
        ])
    }

    /// Paths consulted by the doctor. Constructing them performs no filesystem
    /// access, so the report can inspect an unconfigured installation without
    /// creating its support directory.
    private struct ManifestPaths {
        let supportDirectory: URL
        let settings: URL
        let agents: URL
        let permissions: URL
    }

    // MARK: - Environment

    private static func environmentSection(environment: [String: String]) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        checks.append(
            ZenDoctorCheck(
                id: "environment.platform",
                title: "Operating system",
                status: .info,
                detail: platformDescription()
            )
        )

        checks.append(
            ZenDoctorCheck(
                id: "environment.version",
                title: "ZenCODE version",
                status: .info,
                detail: ZenPackageMetadata.version
            )
        )

        // Home directory must be resolvable for the support directory to exist.
        let home = UserHomeDirectory.current()
        let homeExists = directoryExists(home)
        checks.append(
            ZenDoctorCheck(
                id: "environment.home",
                title: "Home directory",
                status: homeExists ? .ok : .failure,
                detail: homeExists
                    ? "Resolved home directory at \(home.path)."
                    : "Home directory \(home.path) does not exist or is not a directory.",
                remedy: homeExists
                    ? nil
                    : "Ensure the current user has a valid home directory; ZenCODE stores its configuration under ~/.zencode."
            )
        )

        // A support-directory override is a common source of confusion.
        if let override = environment[AppStorageDirectory.supportDirectoryEnvironmentKey]?.nilIfBlank {
            checks.append(
                ZenDoctorCheck(
                    id: "environment.supportOverride",
                    title: "Support directory override",
                    status: .info,
                    detail: "\(AppStorageDirectory.supportDirectoryEnvironmentKey) is set to \(override).",
                    remedy: "Unset \(AppStorageDirectory.supportDirectoryEnvironmentKey) to use the default ~/.zencode."
                )
            )
        }

        return ZenDoctorSection(title: "Environment", checks: checks)
    }

    // MARK: - Support files

    private static func supportFilesSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let supportDirectory = paths.supportDirectory
        let supportExists = directoryExists(supportDirectory, fileManager: fileManager)
        checks.append(
            ZenDoctorCheck(
                id: "support.directory",
                title: "Support directory",
                status: supportExists ? .ok : .warning,
                detail: supportExists
                    ? "Present at \(supportDirectory.path)."
                    : "Not created yet at \(supportDirectory.path).",
                remedy: supportExists
                    ? nil
                    : "Run zen; setup opens automatically and creates ~/.zencode and its base files."
            )
        )

        if supportExists {
            checks.append(directoryWritabilityCheck(supportDirectory, fileManager: fileManager))
        }

        return ZenDoctorSection(title: "Support files", checks: checks)
    }

    private static func directoryWritabilityCheck(
        _ directory: URL,
        fileManager: FileManager
    ) -> ZenDoctorCheck {
        let writable = fileManager.isWritableFile(atPath: directory.path)
        return ZenDoctorCheck(
            id: "support.writable",
            title: "Support directory permissions",
            status: writable ? .ok : .failure,
            detail: writable
                ? "The support directory is writable."
                : "The support directory at \(directory.path) is not writable.",
            remedy: writable
                ? nil
                : "Fix the ownership/permissions of the support directory so the current user can write to it."
        )
    }

    // MARK: - Configuration

    private static func configurationSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let settingsURL = paths.settings
        let agentsURL = paths.agents

        // Read-only setup status. The manifests are decoded directly from their
        // raw bytes rather than through the manifest stores, which call
        // `SensitiveFilePermissions.hardenExistingFile` on load and would mutate
        // file permissions. The doctor must inspect without side effects.
        let settingsRead = readSettingsManifest(at: settingsURL, fileManager: fileManager)
        let agentsRead = readAgentProfiles(at: agentsURL, fileManager: fileManager)
        checks.append(setupStatusCheck(
            settingsRead: settingsRead,
            agentsRead: agentsRead,
            settingsURL: settingsURL,
            agentsURL: agentsURL
        ))

        // settings.json contains provider keys, so its privacy is worth checking
        // whenever the file is present (even if it does not decode).
        if case .missing = settingsRead {
            // No file: nothing to report.
        } else {
            checks.append(filePrivacyCheck(
                id: "configuration.settingsPrivacy",
                title: "settings.json privacy",
                url: settingsURL,
                fileManager: fileManager
            ))
        }

        // Model configuration summary (counts and names only, never keys).
        if case let .value(manifest) = settingsRead {
            checks.append(modelsCheck(manifest))
            checks.append(selectedModelCheck(manifest))
        } else {
            checks.append(
                ZenDoctorCheck(
                    id: "configuration.models",
                    title: "Providers and models",
                    status: .warning,
                    detail: "No readable settings.json, so no models are configured.",
                    remedy: "Run zen; setup opens automatically so you can configure at least one model."
                )
            )
            checks.append(
                ZenDoctorCheck(
                    id: "configuration.selectedModel",
                    title: "Default model & thinking",
                    status: .warning,
                    detail: "No readable settings.json, so no default model or thinking level can be verified.",
                    remedy: "Run zen; setup opens automatically so you can configure the default model and thinking level."
                )
            )
        }

        // Agents manifest summary (names only). Keep this required check visible
        // even when the manifest is missing or invalid.
        checks.append(agentsCheck(agentsRead, agentsURL: agentsURL))
        if case .missing = agentsRead {
            // No file: there is no privacy mode to inspect.
        } else {
            checks.append(filePrivacyCheck(
                id: "configuration.agentsPrivacy",
                title: "agents.json privacy",
                url: agentsURL,
                fileManager: fileManager
            ))
        }

        return ZenDoctorSection(title: "Configuration", checks: checks)
    }

    private static func setupStatusCheck(
        settingsRead: ManifestReadOutcome<AgentSettingsManifest>,
        agentsRead: ManifestReadOutcome<[AgentProfile]>,
        settingsURL: URL,
        agentsURL: URL
    ) -> ZenDoctorCheck {
        // Agents are validated first, mirroring ZenInspector, so a missing or
        // invalid agents.json is reported before settings.json.
        switch agentsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .warning,
                detail: "Missing agents.json at \(agentsURL.path).",
                remedy: "Run zen; setup opens automatically to create the missing configuration."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .failure,
                detail: "agents.json at \(agentsURL.path) could not be read.",
                remedy: "Repair or recreate the file, then run zen; setup opens automatically when configuration is invalid."
            )
        case .value:
            break
        }

        switch settingsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .warning,
                detail: "Missing settings.json at \(settingsURL.path).",
                remedy: "Run zen; setup opens automatically to create the missing configuration."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .failure,
                detail: "settings.json at \(settingsURL.path) could not be read.",
                remedy: "Repair or recreate the file, then run zen; setup opens automatically when configuration is invalid."
            )
        case .value:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .ok,
                detail: "ZenCODE is configured."
            )
        }
    }

    private static func modelsCheck(_ manifest: AgentSettingsManifest) -> ZenDoctorCheck {
        let count = manifest.models.count
        let remoteProvidersWithoutKey = manifest.models.compactMap { model -> AgentRemoteProvider? in
            guard model.kind == .remoteAPI,
                  let provider = model.provider,
                  provider.requiresAPIKey else {
                return nil
            }
            let providerKey = provider.id.uuidString.lowercased()
            guard manifest.remoteAPIKeysByProviderID[providerKey]?.nilIfBlank == nil,
                  model.apiKey?.nilIfBlank == nil else {
                return nil
            }
            return provider
        }

        if count == 0 {
            return ZenDoctorCheck(
                id: "configuration.models",
                title: "Providers and models",
                status: .warning,
                detail: "No models are configured.",
                remedy: "Run zen; setup opens automatically so you can configure at least one model."
            )
        }

        if !remoteProvidersWithoutKey.isEmpty {
            let modelsByProviderID = Dictionary(grouping: remoteProvidersWithoutKey) { provider in
                provider.id
            }
            let providers: [(id: UUID, title: String, modelCount: Int)] = modelsByProviderID.map { entry in
                let provider = entry.value[0]
                return (
                    id: entry.key,
                    title: provider.displayTitle,
                    modelCount: entry.value.count
                )
            }.sorted { lhs, rhs in
                let titleComparison = lhs.title.compare(
                    rhs.title,
                    options: String.CompareOptions.caseInsensitive,
                    locale: Locale(identifier: "en_US_POSIX")
                )
                if titleComparison == .orderedSame {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return titleComparison == .orderedAscending
            }
            let summary = providers.map { provider in
                "\(provider.title) (\(provider.modelCount) model(s))"
            }.joined(separator: ", ")
            return ZenDoctorCheck(
                id: "configuration.models",
                title: "Providers and models",
                status: .warning,
                detail: "\(count) model(s) configured; \(providers.count) remote provider(s) have no stored API key: \(summary).",
                remedy: "Run /setup to save an API key for each provider."
            )
        }

        return ZenDoctorCheck(
            id: "configuration.models",
            title: "Providers and models",
            status: .ok,
            detail: "\(count) model(s) configured."
        )
    }

    private static func selectedModelCheck(_ manifest: AgentSettingsManifest) -> ZenDoctorCheck {
        guard let selected = manifest.selectedModelID?.nilIfBlank else {
            return ZenDoctorCheck(
                id: "configuration.selectedModel",
                title: "Default model & thinking",
                status: .warning,
                detail: "No default model is selected, so its thinking level cannot be verified.",
                remedy: "Select a default model and thinking level with the /setup command in zen."
            )
        }
        guard let model = manifest.models.first(where: { $0.matches(selected) }) else {
            return ZenDoctorCheck(
                id: "configuration.selectedModel",
                title: "Default model & thinking",
                status: .warning,
                detail: "Default model \(selected) is not among configured models, so its thinking level cannot be verified.",
                remedy: "Reselect a configured model and thinking level with the /setup command in zen."
            )
        }
        let thinking = model.supportsThinking
            ? model.thinkingSelection(for: manifest.selectedThinkingSelection)?.displayTitle ?? "default"
            : "not supported"
        return ZenDoctorCheck(
            id: "configuration.selectedModel",
            title: "Default model & thinking",
            status: .ok,
            detail: "Default model is \(selected); thinking: \(thinking)."
        )
    }

    private static func agentsCheck(
        _ agentsRead: ManifestReadOutcome<[AgentProfile]>,
        agentsURL: URL
    ) -> ZenDoctorCheck {
        switch agentsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: .warning,
                detail: "Missing agents.json at \(agentsURL.path).",
                remedy: "Run zen; setup opens automatically and creates the default agent profiles."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: .failure,
                detail: "agents.json at \(agentsURL.path) could not be read.",
                remedy: "Repair or recreate the file, then run zen; setup opens automatically when configuration is invalid."
            )
        case let .value(agents):
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: agents.isEmpty ? .warning : .ok,
                detail: agents.isEmpty
                    ? "No agent profiles are configured."
                    : "\(agents.count) agent profile(s): \(agents.map(\.displayName).joined(separator: ", ")).",
                remedy: agents.isEmpty
                    ? "Run zen; setup opens automatically and creates the default agent profiles."
                    : nil
            )
        }
    }

    // MARK: - Permissions

    private static func permissionsSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let permissionsURL = paths.permissions
        let permissionsRead = readPermissionsManifest(at: permissionsURL, fileManager: fileManager)
        switch permissionsRead {
        case let .value(manifest):
            let count = manifest.localExecAllowedCommands.count
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .ok,
                    detail: count == 0
                        ? "No commands are pre-approved for local.exec; each run asks for consent."
                        : "\(count) command pattern(s) are pre-approved for local.exec.",
                    remedy: nil
                )
            )
            checks.append(filePrivacyCheck(
                id: "permissions.filePrivacy",
                title: "permissions.json privacy",
                url: permissionsURL,
                fileManager: fileManager
            ))
        case .invalid:
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .failure,
                    detail: "permissions.json at \(permissionsURL.path) could not be read.",
                    remedy: "Repair or delete permissions.json; it is recreated when you next approve a command."
                )
            )
            checks.append(filePrivacyCheck(
                id: "permissions.filePrivacy",
                title: "permissions.json privacy",
                url: permissionsURL,
                fileManager: fileManager
            ))
        case .missing:
            checks.append(
                ZenDoctorCheck(
                    id: "permissions.localExec",
                    title: "local.exec allowlist",
                    status: .info,
                    detail: "No permissions.json yet; local.exec asks for consent on first use.",
                    remedy: nil
                )
            )
        }

        return ZenDoctorSection(title: "Permissions", checks: checks)
    }

    private static func filePrivacyCheck(
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

    // MARK: - Diagnostics logging

    private static func diagnosticsSection(
        environment: [String: String]
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        // Resolve the logger configuration directly from the environment rather
        // than consulting ZenLogger.isEnabled. Resolution is pure (the system
        // log is opened lazily by the platform), so the doctor stays read-only
        // even when logging is enabled, without ever touching stdout.
        if let configuration = ZenLogger.previewConfiguration(environment: environment) {
            let level = configuration.minimumLevel.label
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.logging",
                    title: "Diagnostic logging",
                    status: .info,
                    detail: "Enabled at level \(level); output is redacted and written to the \(configuration.destinationDescription) (subsystem \(SystemLogEmitter.subsystem)).",
                    remedy: "Unset ZENCODE_LOG to disable diagnostic logging."
                )
            )
        } else {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.logging",
                    title: "Diagnostic logging",
                    status: .info,
                    detail: "Disabled (default). No diagnostic output is produced and stdout stays clean.",
                    remedy: "Set ZENCODE_LOG=debug to emit redacted diagnostics to the system log (view it with /tools logs)."
                )
            )
        }

        // Legacy destination variables no longer do anything; surface them so a
        // stale configuration is not mistaken for working diagnostics.
        if environment["ZENCODE_LOG_FILE"]?.nilIfBlank != nil {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.loggingLegacyFile",
                    title: "Legacy diagnostic log file",
                    status: .warning,
                    detail: "ZENCODE_LOG_FILE is set, but diagnostics no longer write to an application-owned file; the value is ignored.",
                    remedy: "Unset ZENCODE_LOG_FILE. Set ZENCODE_LOG to a level to emit redacted diagnostics to the system log."
                )
            )
        }
        if let rawEnable = environment["ZENCODE_LOG"]?.nilIfBlank,
            ZenLoggerConfiguration.isLegacyDestinationValue(rawEnable.lowercased()) {
            checks.append(
                ZenDoctorCheck(
                    id: "diagnostics.loggingLegacyDestination",
                    title: "Invalid ZENCODE_LOG value",
                    status: .warning,
                    detail: "ZENCODE_LOG=\(rawEnable) named the removed stderr destination, so diagnostic logging stays disabled.",
                    remedy: "Set ZENCODE_LOG to a level such as debug to emit redacted diagnostics to the system log."
                )
            )
        }

        return ZenDoctorSection(title: "Diagnostics", checks: checks)
    }

    // MARK: - Read-only manifest access

    /// Outcome of a read-only manifest decode. Decoding happens directly from the
    /// raw file bytes so that no manifest store is consulted: the stores call
    /// `SensitiveFilePermissions.hardenExistingFile` on load, which would mutate
    /// file permissions and break the doctor's read-only guarantee.
    private enum ManifestReadOutcome<T> {
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

    private static func readSettingsManifest(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestReadOutcome<AgentSettingsManifest> {
        readManifest(at: url, fileManager: fileManager) { manifest in
            manifest.version >= AgentSettingsManifest.minimumSupportedVersion
                && manifest.version <= AgentSettingsManifest.currentVersion
        }
    }

    private static func readPermissionsManifest(
        at url: URL,
        fileManager: FileManager
    ) -> ManifestReadOutcome<AgentPermissionsManifest> {
        readManifest(at: url, fileManager: fileManager) { manifest in
            manifest.version >= AgentPermissionsManifest.minimumSupportedVersion
                && manifest.version <= AgentPermissionsManifest.currentVersion
        }
    }

    private static func readAgentProfiles(
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

    private static func directoryExists(
        _ url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private static func platformDescription() -> String {
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
    private static func isWindowsSubsystemForLinux() -> Bool {
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
