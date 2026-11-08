//
//  ZenAppLaunchArgumentsTests.swift
//  ZenAppSessionTests
//
//  The options the app reads from its command line, and how a launch
//  configuration that cannot be built is reported: a wrong argument is not a
//  missing setup. Every configuration is read from a temporary support
//  directory.
//

import Foundation
import Testing
import ZenCODECore
@testable import ZenAppSession

@Suite("App launch arguments")
struct ZenAppLaunchArgumentsTests {
    @Test("only the forwarded options and their values are kept, after the executable name")
    func onlyTheForwardedOptionsAreKept() throws {
        let arguments = try ZenAppLaunchArguments.configurationArguments(from: [
            "/Users/me/.zencode/app/current/ZenCODE",
            "-NSDocumentRevisionsDebugMode", "YES",
            "--agent", "Developer",
            "-ApplePersistenceIgnoreState", "YES",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project",
            "--max-tool-rounds", "3"
        ])
        #expect(arguments == [
            "ZenCODE",
            "--agent", "Developer",
            "--model", "openrouter:openrouter/auto",
            "--skills", "all",
            "--working-directory", "/tmp/project"
        ])
    }

    @Test("without options the arguments are the executable name alone")
    func withoutOptions() throws {
        #expect(try ZenAppLaunchArguments.configurationArguments(from: []) == ["ZenCODE"])
        #expect(try ZenAppLaunchArguments.configurationArguments(from: ["/path/ZenCODE"]) == ["ZenCODE"])
        #expect(
            try ZenAppLaunchArguments.configurationArguments(
                from: ["/path/ZenCODE", "-NSDocumentRevisionsDebugMode", "YES"],
                executableName: "zen"
            ) == ["zen"]
        )
    }

    @Test("a forwarded option without its value is an error", arguments: ["--agent", "--model", "--skills", "--working-directory"])
    func aMissingValueIsAnError(option: String) {
        do {
            _ = try ZenAppLaunchArguments.configurationArguments(from: ["/path/ZenCODE", "--agent", "Developer", option])
            Issue.record("\(option) without a value was accepted")
        } catch {
            #expect(error.localizedDescription == "Missing value for \(option).")
        }
    }

    @Test("an argument failure shows the error without the setup hint")
    func theInvalidArgumentsMessage() {
        let failure = ZenAppLaunchFailure.invalidArguments("Unknown agent 'Nobody'.")
        #expect(failure.message == "ZenCODE: Unknown agent 'Nobody'.")
        #expect(!failure.message.contains(ZenAppLaunchFailure.notConfiguredMessage))
    }
}

@Suite("App launch configuration", .serialized)
struct ZenAppLaunchConfigurationTests {
    @Test("a support directory without settings is not configured")
    func withoutSettings() async throws {
        try await withSupportDirectory(configured: false) { _ in
            let result = await ZenAppRuntime.readLaunchConfiguration(arguments: ["ZenCODE"], migratingProviderKeys: false)
            guard case let .failure(.notConfigured(message)) = result else {
                Issue.record("Expected notConfigured, got \(result)")
                return
            }
            #expect(message.hasPrefix(ZenAppLaunchFailure.notConfiguredMessage + "\n"))
        }
    }

    @Test("an unknown argument is an argument failure, even before the settings are read")
    func anUnknownArgument() async throws {
        try await withSupportDirectory(configured: false) { _ in
            let result = await ZenAppRuntime.readLaunchConfiguration(
                arguments: ["ZenCODE", "--bogus"],
                migratingProviderKeys: false
            )
            guard case let .failure(.invalidArguments(description)) = result else {
                Issue.record("Expected invalidArguments, got \(result)")
                return
            }
            #expect(description == "Unknown argument: --bogus")
        }
    }

    @Test("an unknown agent is an argument failure, not a missing setup")
    func anUnknownAgent() async throws {
        try await withSupportDirectory(configured: true) { _ in
            let result = await ZenAppRuntime.readLaunchConfiguration(
                arguments: ["ZenCODE", "--agent", "Nobody"],
                migratingProviderKeys: false
            )
            guard case let .failure(failure) = result, case let .invalidArguments(description) = failure else {
                Issue.record("Expected invalidArguments, got \(result)")
                return
            }
            #expect(description.hasPrefix("Unknown agent 'Nobody'."))
            #expect(failure.message == "ZenCODE: \(description)")
            #expect(!failure.message.contains("Run `zen --setup`"))
        }
    }

    @Test("the forwarded options reach the configuration")
    func theForwardedOptions() async throws {
        try await withSupportDirectory(configured: true) { workspace in
            let result = await ZenAppRuntime.readLaunchConfiguration(
                arguments: [
                    "ZenCODE",
                    "--model", "zen-app-model",
                    "--skills", "none",
                    "--working-directory", workspace.path
                ],
                migratingProviderKeys: false
            )
            let configuration = try result.get()
            #expect(configuration.workingDirectory == workspace.standardizedFileURL.resolvingSymlinksInPath())
            #expect(configuration.modelID == "zen-app-model")
            #expect(configuration.initialSkillSelection == "none")
            #expect(configuration.selectedAgent != nil)
        }
    }

    /// Runs `body` with a temporary support directory, with settings and agent
    /// profiles when `configured`, and passes it a temporary workspace.
    private func withSupportDirectory(
        configured: Bool,
        _ body: @escaping @Sendable (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-launch-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            if configured {
                let model = AgentSettingsModelManifest(
                    id: "zen-app-model",
                    kind: .remoteAPI,
                    modelID: "local/zen-app-model"
                )
                try AgentSettingsManifestStore.save(
                    AgentSettingsManifest(models: [model], selectedModelID: model.id),
                    to: AgentSettingsManifestStore.settingsURL()
                )
                try AgentProfileStore.save(AgentProfileStore.defaultProfiles())
            }
            try await body(workspace)
        }
    }
}
