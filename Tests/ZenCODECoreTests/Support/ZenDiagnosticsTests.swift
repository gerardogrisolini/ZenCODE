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
    func loggerRedactsFileOutputAndNeverWritesToStandardOutput() throws {
        let root = try temporaryDirectory()
        defer {
            ZenLogger.configure(nil)
            try? FileManager.default.removeItem(at: root)
        }

        let logURL = root.appendingPathComponent("diagnostics.log")
        ZenLogger.configure(
            ZenLoggerConfiguration(
                minimumLevel: .debug,
                destination: .file(logURL)
            )
        )

        let secret = "sk-abcdefghijklmnopqrstuvwxyz123456"
        ZenLogger.error(.diagnostics, "Authorization: Bearer token-value-12345 api_key=\(secret)")

        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.contains("[Diagnostics][ERROR]"))
        #expect(text.contains(ZenSecretRedactor.placeholder))
        #expect(!text.contains(secret))
        #expect(!text.contains("token-value-12345"))
    }

    @Test
    func loggerPreviewDoesNotCreateItsDefaultLogDirectory() throws {
        let parent = try temporaryDirectory()
        let supportDirectory = parent.appendingPathComponent("support", isDirectory: true)
        defer {
            ZenLogger.configure(nil)
            try? FileManager.default.removeItem(at: parent)
        }
        let configuration = ZenLogger.previewConfiguration(
            environment: ["ZENCODE_LOG": "debug"],
            supportDirectory: supportDirectory
        )

        #expect(configuration?.minimumLevel == .debug)
        #expect(configuration?.destinationDescription == supportDirectory
            .appendingPathComponent("logs/zencode.log").path)
        #expect(!FileManager.default.fileExists(atPath: supportDirectory.path))
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
        #expect(rendered.contains(ZenSecretRedactor.placeholder))
        #expect(!rendered.contains(secret))
        #expect(!rendered.contains("token-value-12345"))
        #expect(rendered.contains("Summary: no failures, 1 warning(s)."))
    }

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
}
