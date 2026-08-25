//
//  ZenDiagnosticsTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct ZenDiagnosticsTests {
    @Test
    func secretRedactorRemovesRecognizedCredentials() {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        let redacted = ZenSecretRedactor.redact(
            "Authorization: Bearer token-value-12345 api_key=\(secret)"
        )

        #expect(!redacted.contains(secret))
        #expect(!redacted.contains("token-value-12345"))
        #expect(redacted.contains(ZenSecretRedactor.placeholder))
    }

    @Test
    func systemLogRecordIsRedactedPublicAndBounded() {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        let record = ZenLogger.systemLogRecord(
            level: .error,
            category: .diagnostics,
            message: "Authorization: Bearer token-value-12345 api_key=\(secret)"
        )

        #expect(record.category == "diagnostics-Diagnostics")
        #expect(record.severity == .error)
        #expect(record.message.contains("[Diagnostics][ERROR]"))
        #expect(record.message.contains(ZenSecretRedactor.placeholder))
        #expect(!record.message.contains(secret))
        #expect(!record.message.contains("token-value-12345"))
        #expect(!record.message.contains(Date().description))
    }

    @Test
    func oversizedMessagesAreTruncatedToTheSafeLimit() {
        let record = ZenLogger.systemLogRecord(
            level: .info,
            category: .diagnostics,
            message: String(repeating: "a", count: ZenLogger.maximumMessageCharacters + 5_000)
        )

        #expect(record.message.count == ZenLogger.maximumMessageCharacters + 1)
        #expect(record.message.hasSuffix("…"))
    }

    @Test
    func levelsMapToSystemLogSeveritiesAndCategoriesStayIdentifiable() {
        #expect(ZenLogger.systemLogSeverity(for: .debug) == .debug)
        #expect(ZenLogger.systemLogSeverity(for: .info) == .info)
        #expect(ZenLogger.systemLogSeverity(for: .warning) == .warning)
        #expect(ZenLogger.systemLogSeverity(for: .error) == .error)
        #expect(SystemLogSeverity.debug.syslogPriority == "user.debug")
        #expect(SystemLogSeverity.info.syslogPriority == "user.info")
        #expect(SystemLogSeverity.notice.syslogPriority == "user.notice")
        #expect(SystemLogSeverity.warning.syslogPriority == "user.warning")
        #expect(SystemLogSeverity.error.syslogPriority == "user.err")
        #expect(ZenLogger.diagnosticCategory(for: .memory) == "diagnostics-MemoryService")
        #expect(SystemLogEmitter.subsystem == "com.zencode.zen")
        #expect(SystemLogEmitter.linuxTag == "zen")
    }

    @Test
    func lazyEvaluationSkipsMessageClosuresBelowTheThreshold() {
        defer { ZenLogger.configure(nil) }
        ZenLogger.configure(
            ZenLoggerConfiguration(minimumLevel: .error, destination: .systemLog)
        )

        var evaluated = false
        ZenLogger.log(.info, .diagnostics) {
            evaluated = true
            return "never rendered"
        }
        #expect(!evaluated)

        ZenLogger.log(.error, .diagnostics) {
            evaluated = true
            return "rendered"
        }
        #expect(evaluated)
    }

    @Test
    func loggerEmittingDoesNotCreateApplicationFiles() throws {
        let root = try temporaryDirectory()
        defer {
            ZenLogger.configure(nil)
            try? FileManager.default.removeItem(at: root)
        }
        ZenLogger.configure(
            ZenLoggerConfiguration(minimumLevel: .debug, destination: .systemLog)
        )

        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        ZenLogger.error(.diagnostics, "Authorization: Bearer token-value-12345 api_key=\(secret)")
        ZenLogger.debug(.memory, "diagnostic body")

        #expect(ZenLogger.isEnabled)
        #expect(ZenLogger.activeLevel == .debug)
        #expect(ZenLogger.destinationDescription == "system log")
        // The system-log backend owns storage: no application-owned log
        // directory or file may be created anywhere under the isolated root.
        #expect(try contentsOfDirectory(root).isEmpty)
    }

    @Test
    func resolutionUsesZencodeLogAsTheOnlyDiagnosticConfigurationVariable() {
        #expect(
            ZenLoggerConfiguration.resolve(environment: [:])?.minimumLevel == nil
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "1"])?
                .minimumLevel == .info
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "true"])?
                .minimumLevel == .info
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "debug"])?
                .minimumLevel == .debug
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "warning"])?
                .minimumLevel == .warning
        )
        // ZENCODE_LOG_LEVEL was removed and cannot enable or change diagnostics.
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG_LEVEL": "debug"]) == nil
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "1", "ZENCODE_LOG_LEVEL": "warning"])?
                .minimumLevel == .info
        )
        #expect(
            ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": "debug", "ZENCODE_LOG_LEVEL": "error"])?
                .minimumLevel == .debug
        )
        for disabled in ["0", "false", "off", "no", "disable", "disabled", "  "] {
            #expect(
                ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": disabled]) == nil,
                "ZENCODE_LOG=\(disabled) must keep logging disabled"
            )
        }
    }

    @Test
    func legacyDestinationsAreRejectedInsteadOfSilentlyEnablingTheSystemLog() {
        for legacy in ["stderr", "STDERR", "2"] {
            #expect(
                ZenLoggerConfiguration.resolve(environment: ["ZENCODE_LOG": legacy]) == nil,
                "ZENCODE_LOG=\(legacy) must not enable diagnostics"
            )
        }
        #expect(ZenLoggerConfiguration.isLegacyDestinationValue("stderr"))
        #expect(ZenLoggerConfiguration.isLegacyDestinationValue("2"))
        #expect(!ZenLoggerConfiguration.isLegacyDestinationValue("debug"))
        #expect(!ZenLoggerConfiguration.isLegacyDestinationValue("1"))
        #expect(!ZenLoggerConfiguration.isLegacyDestinationValue("bogus"))

        // ZENCODE_LOG_FILE is ignored as a legacy destination override.
        #expect(
            ZenLoggerConfiguration.resolve(
                environment: ["ZENCODE_LOG": "debug", "ZENCODE_LOG_FILE": "/tmp/legacy.log"]
            )?.destinationDescription == "system log"
        )
    }

    @Test
    func configureNilRestoresResolutionFromTheEnvironment() {
        defer { ZenLogger.configure(nil) }
        ZenLogger.configure(
            ZenLoggerConfiguration(minimumLevel: .error, destination: .systemLog)
        )
        #expect(ZenLogger.activeLevel == .error)

        ZenLogger.configure(nil)
        // The test process runs without ZENCODE_LOG, so resolution is disabled.
        #expect(!ZenLogger.isEnabled)
        #expect(ZenLogger.activeLevel == nil)
        #expect(ZenLogger.destinationDescription == nil)
    }

    /// The shared store reads the real process environment, where `ZENCODE_LOG`
    /// is unset, so "restore the environment" and "stay disabled" would look
    /// identical. A store built on an injected environment separates them:
    /// clearing the override must re-enable from the environment, while an
    /// explicit disable must win over the very same environment.
    @Test
    func clearingTheOverrideRestoresTheEnvironmentWhileDisableWins() {
        let store = ZenLogConfigurationStore(
            environmentProvider: { ["ZENCODE_LOG": "debug"] }
        )

        #expect(store.resolvedConfiguration()?.minimumLevel == .debug)

        store.configure(
            .configuration(
                ZenLoggerConfiguration(minimumLevel: .error, destination: .systemLog)
            )
        )
        #expect(store.resolvedConfiguration()?.minimumLevel == .error)

        // Restore: the injected environment enables debug again.
        store.configure(.environment)
        #expect(store.resolvedConfiguration()?.minimumLevel == .debug)

        // Disable: unambiguously off despite the enabling environment.
        store.configure(.disabled)
        #expect(store.resolvedConfiguration() == nil)

        // And restoring once more re-enables, proving disable is not sticky.
        store.configure(.environment)
        #expect(store.resolvedConfiguration()?.minimumLevel == .debug)
    }

    @Test
    func explicitDisableOverridesAnEnablingEnvironmentOnTheStore() {
        let store = ZenLogConfigurationStore(
            environmentProvider: { ["ZENCODE_LOG": "warning"] }
        )
        #expect(store.resolvedConfiguration()?.minimumLevel == .warning)
        store.configure(.disabled)
        #expect(store.resolvedConfiguration() == nil)
    }

    @Test
    func linuxLoggerBridgeUsesTaggedPrioritizedArgumentsAndNullStdio() throws {
        let record = SystemLogRecord(
            category: "diagnostics-Diagnostics",
            severity: .warning,
            message: "-n injected --nonsense body"
        )

        #expect(
            SystemLogEmitter.loggerCommandArguments(for: record) == [
                "-t", "zen",
                "-p", "user.warning",
                "--", "-n injected --nonsense body"
            ]
        )

        // The process is built but never started: no `logger(1)` invocation and
        // no system-log side effect occurs in tests.
        let process = SystemLogEmitter.makeLoggerProcess(
            executable: "/usr/bin/logger",
            record: record
        )
        #expect(process.executableURL?.path == "/usr/bin/logger")
        #expect(process.arguments == SystemLogEmitter.loggerCommandArguments(for: record))
        #expect(process.standardInput as? FileHandle == FileHandle.nullDevice)
        #expect(process.standardOutput as? FileHandle == FileHandle.nullDevice)
        #expect(process.standardError as? FileHandle == FileHandle.nullDevice)
        #expect(!process.isRunning)

        for severity in [
            SystemLogSeverity.debug, .info, .notice, .warning, .error
        ] {
            let arguments = SystemLogEmitter.loggerCommandArguments(
                for: SystemLogRecord(category: "c", severity: severity, message: "m")
            )
            #expect(arguments[3] == severity.syslogPriority)
            #expect(arguments[4] == "--")
        }
    }

    @Test
    func loggerExecutableResolutionPrefersUsrBinAndToleratesAbsence() {
        #expect(SystemLogEmitter.resolveLoggerExecutable { _ in true } == "/usr/bin/logger")
        #expect(
            SystemLogEmitter.resolveLoggerExecutable { $0 == "/bin/logger" } == "/bin/logger"
        )
        #expect(SystemLogEmitter.resolveLoggerExecutable { _ in false } == nil)
    }

    @Test
    func previewConfigurationIsReadOnlyAndPointsAtTheSystemLog() throws {
        let parent = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let environment = ["ZENCODE_LOG": "debug"]
        let configuration = ZenLogger.previewConfiguration(environment: environment)
        let historicalConfiguration = ZenLogger.previewConfiguration(
            environment: environment,
            supportDirectory: parent
        )

        #expect(configuration?.minimumLevel == .debug)
        #expect(configuration?.destination == .systemLog)
        #expect(configuration?.destinationDescription == "system log")
        #expect(historicalConfiguration == configuration)
        // Resolution is pure: no support directory or file is ever created.
        #expect(try contentsOfDirectory(parent).isEmpty)
    }

    @Test
    func doctorReadsLegacyManifestsWithoutChangingPermissions() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let settingsURL = root.appendingPathComponent("settings.json")
        let agentsURL = root.appendingPathComponent("agents.json")
        let permissionsURL = root.appendingPathComponent("permissions.json")
        let encoder = JSONEncoder()
        try encoder.encode(AgentSettingsManifest(models: [])).write(to: settingsURL)
        try encoder.encode(
            AgentProfileManifest(agents: AgentProfileStore.defaultProfiles())
        ).write(to: agentsURL)
        try encoder.encode(AgentPermissionsManifest()).write(to: permissionsURL)
        for url in [settingsURL, agentsURL, permissionsURL] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }

        let before = try [settingsURL, agentsURL, permissionsURL].map { try fileMode(at: $0) }
        let report = ZenDoctor.runReport(supportDirectory: root)
        let after = try [settingsURL, agentsURL, permissionsURL].map { try fileMode(at: $0) }

        #expect(before == [0o644, 0o644, 0o644])
        #expect(after == before)
        #expect(report.allChecks.contains {
            $0.id == "configuration.settingsPrivacy" && $0.status == .warning
        })
        #expect(report.allChecks.contains {
            $0.id == "permissions.filePrivacy" && $0.status == .warning
        })
        #expect(report.allChecks.contains {
            $0.id == "configuration.agentsPrivacy" && $0.status == .warning
        })
    }

    @Test
    func doctorReportsSystemLogDestinationAndLegacyVariables() throws {
        // Enabled: describes the system log and the shared subsystem.
        let enabled = ZenDoctor.runReport(
            environment: ["ZENCODE_LOG": "debug"],
            supportDirectory: FileManager.default.temporaryDirectory
        )
        let enabledCheck = try #require(
            enabled.allChecks.first { $0.id == "diagnostics.logging" }
        )
        #expect(enabledCheck.status == .info)
        #expect(enabledCheck.detail.contains("system log"))
        #expect(enabledCheck.detail.contains(SystemLogEmitter.subsystem))
        #expect(!enabled.allChecks.contains { $0.id.hasPrefix("diagnostics.loggingLegacy") })

        // ZENCODE_LOG_FILE is surfaced as an ignored legacy destination.
        let legacyFile = ZenDoctor.runReport(
            environment: ["ZENCODE_LOG": "debug", "ZENCODE_LOG_FILE": "/tmp/legacy.log"],
            supportDirectory: FileManager.default.temporaryDirectory
        )
        let legacyFileCheck = try #require(
            legacyFile.allChecks.first { $0.id == "diagnostics.loggingLegacyFile" }
        )
        #expect(legacyFileCheck.status == .warning)
        #expect(legacyFileCheck.detail.contains("ZENCODE_LOG_FILE"))
        #expect(legacyFileCheck.remedy == "Unset ZENCODE_LOG_FILE. Set ZENCODE_LOG to a level to emit redacted diagnostics to the system log.")

        // ZENCODE_LOG=stderr no longer enables logging and is reported as invalid.
        let legacyStderr = ZenDoctor.runReport(
            environment: ["ZENCODE_LOG": "stderr"],
            supportDirectory: FileManager.default.temporaryDirectory
        )
        let disabledCheck = try #require(
            legacyStderr.allChecks.first { $0.id == "diagnostics.logging" }
        )
        #expect(disabledCheck.detail.contains("Disabled"))
        let legacyDestinationCheck = try #require(
            legacyStderr.allChecks.first { $0.id == "diagnostics.loggingLegacyDestination" }
        )
        #expect(legacyDestinationCheck.status == .warning)
        #expect(legacyDestinationCheck.detail.contains("stderr"))

        // ZENCODE_LOG=2 is equally legacy and keeps diagnostics disabled.
        let legacyTwo = ZenDoctor.runReport(
            environment: ["ZENCODE_LOG": "2"],
            supportDirectory: FileManager.default.temporaryDirectory
        )
        #expect(legacyTwo.allChecks.contains {
            $0.id == "diagnostics.loggingLegacyDestination" && $0.status == .warning
        })
        #expect(legacyTwo.allChecks.contains {
            $0.id == "diagnostics.logging" && $0.detail.contains("Disabled")
        })

        // An unrecognized non-legacy value stays generically enabling (historical
        // truthy behavior), so it is not reported as a legacy destination.
        let unrecognized = ZenDoctor.runReport(
            environment: ["ZENCODE_LOG": "bogus"],
            supportDirectory: FileManager.default.temporaryDirectory
        )
        #expect(!unrecognized.allChecks.contains { $0.id == "diagnostics.loggingLegacyDestination" })
        #expect(unrecognized.allChecks.contains {
            $0.id == "diagnostics.logging" && $0.status == .info && $0.detail.contains("Enabled")
        })
    }

    @Test
    func doctorOptionParsesWithoutRequiringPersistedConfiguration() throws {
        let configuration = try AgentConfiguration(arguments: ["zen", "--doctor"])

        #expect(configuration.printDoctor)
        #expect(!configuration.printHelp)
        #expect(!configuration.printVersion)
    }

    @Test
    func doctorReportsOnlyKeyRequiringProvidersWithoutStoredKeys() throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let duplicateFirstProvider = AgentRemoteProvider(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001001")),
            name: "Duplicate provider",
            baseURL: AgentRemoteProvider.defaultOpenRouterBaseURL,
            modelID: "duplicate-first"
        )
        let duplicateSecondProvider = AgentRemoteProvider(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001002")),
            name: "Duplicate provider",
            baseURL: AgentRemoteProvider.defaultOpenRouterBaseURL,
            modelID: "duplicate-second"
        )
        let missingKeyProvider = AgentRemoteProvider(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001003")),
            name: "OpenRouter",
            baseURL: AgentRemoteProvider.defaultOpenRouterBaseURL,
            modelID: "missing-key"
        )
        let storedKeyProvider = AgentRemoteProvider(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001004")),
            name: "Stored key",
            baseURL: AgentRemoteProvider.defaultOpenRouterBaseURL,
            modelID: "stored-key"
        )
        let subscriptionProvider = AgentRemoteProvider(
            id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            name: "Subscription",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
            modelID: "subscription-model"
        )
        let customKeylessProvider = AgentRemoteProvider(
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000001005")),
            name: "Custom keyless",
            baseURL: "https://custom.example.test/v1",
            modelID: "custom-keyless-model"
        )
        let models = [
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "stored-key",
                provider: storedKeyProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "duplicate-second",
                provider: duplicateSecondProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "subscription-model",
                provider: subscriptionProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "custom-keyless-model",
                provider: customKeylessProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "missing-key",
                provider: missingKeyProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "duplicate-first-1",
                provider: duplicateFirstProvider
            ),
            AgentSettingsModelManifest(
                kind: .remoteAPI,
                modelID: "duplicate-first-2",
                provider: duplicateFirstProvider
            ),
        ]
        let manifest = AgentSettingsManifest(
            models: models,
            remoteAPIKeysByProviderID: [
                storedKeyProvider.id.uuidString.lowercased(): "stored-key-value"
            ]
        )
        try JSONEncoder()
            .encode(manifest)
            .write(to: root.appendingPathComponent("settings.json"))

        let report = ZenDoctor.runReport(supportDirectory: root)
        let modelsCheck = try #require(report.allChecks.first { $0.id == "configuration.models" })

        #expect(modelsCheck.status == .warning)
        #expect(
            modelsCheck.detail == "7 model(s) configured; 3 remote provider(s) have no stored API key: Duplicate provider (2 model(s)), Duplicate provider (1 model(s)), OpenRouter (1 model(s))."
        )
        #expect(!modelsCheck.detail.contains("Stored key"))
        #expect(!modelsCheck.detail.contains("Subscription"))
        #expect(!modelsCheck.detail.contains("Custom keyless"))
        #expect(modelsCheck.remedy == "Run /setup to save an API key for each provider.")
    }

    @Test
    func reportRendererReceivesOnlyRedactedFields() {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        let report = ZenDoctorReport(sections: [
            ZenDoctorSection(
                title: "Diagnostics",
                checks: [
                    ZenDoctorCheck(
                        id: "redaction",
                        title: "Redaction",
                        status: .warning,
                        detail: "api_key=\(secret)",
                        remedy: "Remove token=token-value-12345"
                    )
                ]
            )
        ])

        let rendered = ZenDoctorReportRenderer.render(report)
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains("token-value-12345"))
        #expect(rendered.contains(ZenSecretRedactor.placeholder))
    }
}

private func contentsOfDirectory(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path)
}

/// Creates a unique temporary directory for filesystem assertions.
private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZenDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func fileMode(at url: URL) throws -> UInt16 {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let value = attributes[.posixPermissions] as? NSNumber else {
        throw CocoaError(.fileReadUnknown)
    }
    return value.uint16Value & 0o777
}
