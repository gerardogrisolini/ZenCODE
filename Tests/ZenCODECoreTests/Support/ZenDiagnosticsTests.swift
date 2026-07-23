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
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            ZenLogger.configure(nil)
            try? FileManager.default.removeItem(at: parent)
        }
        AppStorageDirectory.configureSupportDirectoryURL(supportDirectory)
        ZenLogger.configure(nil)

        let configuration = ZenLogger.previewConfiguration(
            environment: ["ZENCODE_LOG": "debug"]
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
            AppStorageDirectory.configureSupportDirectoryURL(nil)
            try? FileManager.default.removeItem(at: root)
        }
        AppStorageDirectory.configureSupportDirectoryURL(root)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let settingsURL = AgentSettingsManifestStore.settingsURL()
        let agentsURL = AgentProfileStore.agentsManifestURL()
        let permissionsURL = AgentPermissionsManifestStore.permissionsURL()
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
        let report = ZenDoctor.runReport()
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
