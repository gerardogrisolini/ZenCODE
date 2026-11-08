//
//  ZenCODESetupSessionTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing

@Suite
struct ZenCODESetupSessionTests {
    private static func manifest(
        models: [AgentSettingsModelManifest],
        commands: [String] = []
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            models: models,
            localExecAllowedCommands: commands
        )
    }

    private static func emptyManifest(commands: [String] = []) -> AgentSettingsManifest {
        manifest(models: [], commands: commands)
    }

    private static func remoteManifest(commands: [String] = []) -> AgentSettingsManifest {
        let providerID = "custom"
        let modelID = "test-model"
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "Test provider",
            baseURL: "https://example.invalid/v1",
            modelID: modelID
        )
        let model = AgentSettingsModelManifest(
            id: "remote:test-model",
            kind: .remoteAPI,
            modelID: modelID,
            providerID: providerID,
            provider: provider
        )
        return manifest(models: [model], commands: commands)
    }

    @Test
    func startupSetupRequirementRejectsMissingInvalidAndModelFreeConfiguration() {
        let settingsURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings.json")

        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: nil,
                status: .missingSettings(settingsFileURL: settingsURL)
            )
        )
        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: Self.emptyManifest(),
                status: .ready(settingsFileURL: settingsURL)
            )
        )
        #expect(
            ZenCODESetupRequirement.isRequired(
                manifest: Self.remoteManifest(),
                status: .invalidSettings(
                    settingsFileURL: settingsURL,
                    message: "invalid"
                )
            )
        )
        #expect(
            !ZenCODESetupRequirement.isRequired(
                manifest: Self.remoteManifest(),
                status: .ready(settingsFileURL: settingsURL)
            )
        )
    }

    @Test
    func quickSetupMarksRemoteSettingsChangedAndWrites() {
        var session = SetupSession(originalManifest: nil)
        let configured = Self.remoteManifest(commands: ["ls"])

        session.applyQuickSetup(configured)

        #expect(session.manifest == configured)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: configured, settingsWillBeWritten: true))
    }

    @Test
    func unchangedSectionOnExistingManifestDoesNotForceWrite() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)

        session.apply(SetupSectionConfigurationResult(manifest: original))

        #expect(session.manifest == original)
        // Nothing changed and settings already existed, so no rewrite is forced.
        #expect(session.shouldWriteSettings == false)
        #expect(session.outcome == .write(manifest: original, settingsWillBeWritten: false))
    }

    @Test
    func sectionThatMutatesManifestMarksSettingsChanged() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let mutated = Self.manifest(
            models: original.models,
            commands: ["ls", "cat"]
        )

        session.apply(SetupSectionConfigurationResult(manifest: mutated))

        #expect(session.manifest == mutated)
        #expect(session.shouldWriteSettings)
        #expect(session.outcome == .write(manifest: mutated, settingsWillBeWritten: true))
    }

    @Test
    func clearingAllModelsCannotProduceAWritableOutcome() {
        let original = Self.remoteManifest(commands: ["ls"])
        var session = SetupSession(originalManifest: original)
        let empty = Self.emptyManifest(commands: ["ls"])

        session.apply(SetupSectionConfigurationResult(manifest: empty))

        #expect(session.manifest == empty)
        #expect(session.outcome == .noModels)
    }

    /// Re-running Telegram setup, enabled or not, keeps the reading voice
    /// chosen in `zen --setup` > Voice mode.
    @Test
    func telegramSetupKeepsTheMacOSReadingVoice() {
        let enabledTelegram = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: "token",
            linkedChatID: 1,
            ownerUserID: 2,
            routes: [AgentTelegramRouteManifest(roomID: "default")]
        )
        let readingVoiceOnly = AgentVoiceSettingsManifest(
            enabled: false,
            macOSVoiceIdentifier: "com.apple.voice.premium.it-IT.Federica"
        )
        let transcriptionAndVoice = AgentVoiceSettingsManifest(
            enabled: true,
            macOSVoiceIdentifier: "com.apple.voice.premium.it-IT.Federica"
        )

        // Telegram turned off: transcription goes, the reading voice stays.
        for existing in [readingVoiceOnly, transcriptionAndVoice] {
            #expect(ZenCODESetupRunner.voiceSettings(for: nil, existing: existing) == readingVoiceOnly)
        }
        #expect(
            ZenCODESetupRunner.voiceSettings(
                for: nil,
                existing: AgentVoiceSettingsManifest(enabled: true)
            ) == nil
        )

        // Telegram active: transcription is on, on every platform.
        let reenabled = ZenCODESetupRunner.voiceSettings(for: enabledTelegram, existing: readingVoiceOnly)
        #expect(reenabled == transcriptionAndVoice)

        // The rebuilt settings manifest keeps it too.
        let manifest = AgentSettingsManifest(
            models: [],
            voice: ZenCODESetupRunner.voiceSettings(for: nil, existing: readingVoiceOnly)
        )
        #expect(manifest.voice == readingVoiceOnly)
    }

    @Test
    func updatingResponseLanguagePreservesExistingSettings() {
        let original = Self.remoteManifest(commands: ["ls"])
        let updated = ZenCODESetupRunner.manifestByUpdatingResponseLanguage(
            original,
            responseLanguage: "es"
        )

        #expect(updated.responseLanguage == "es")
        #expect(updated.providers == original.providers)
        #expect(updated.models == original.models)
        #expect(updated.selectedModelID == original.selectedModelID)
        #expect(updated.localExecAllowedCommands == original.localExecAllowedCommands)
    }

    @Test
    func stagedSubscriptionCredentialsSurviveASecondProviderPass() {
        let oldCredentials = CodexAgentCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: Date(timeIntervalSince1970: 1),
            accountID: "old-account"
        )
        let stagedCredentials = CodexAgentCredentials(
            accessToken: "staged-access",
            refreshToken: "staged-refresh",
            expiresAt: Date(timeIntervalSince1970: 2),
            accountID: "staged-account"
        )
        let provider = AgentSettingsProviderManifest(
            id: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            name: "ChatGPT Subscription",
            baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
            chatEndpoint: .responses
        )
        let preservedInput = ZenCODESetupRunner.preserveProviderInput(
            provider: provider,
            models: [],
            apiKey: nil,
            chatGPTSubscriptionCredentials: stagedCredentials
        )
        let resolved = ZenCODESetupRunner.subscriptionCredentials(
            from: [preservedInput],
            fallback: (chatGPT: oldCredentials, anthropic: nil)
        )

        #expect(preservedInput.chatGPTSubscriptionCredentials?.accessToken == "staged-access")
        #expect(resolved.chatGPT?.accessToken == "staged-access")
        #expect(resolved.chatGPT?.refreshToken == "staged-refresh")
    }

    @Test
    func remoteResetRemovesProvidedConfigurationFilesOnce() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: directory)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let settingsURL = directory.appendingPathComponent("settings.json")
        let profilesURL = directory.appendingPathComponent("agents.json")
        let missingURL = directory.appendingPathComponent("missing.json")
        try Data("settings".utf8).write(to: settingsURL)
        try Data("profiles".utf8).write(to: profilesURL)

        let result = try ZenCODESetupRunner.resetRemoteConfiguration(
            fileManager: fileManager,
            configurationURLs: [settingsURL, settingsURL, profilesURL, missingURL]
        )

        #expect(result.removedURLs == [settingsURL.standardizedFileURL, profilesURL.standardizedFileURL])
        #expect(result.missingURLs == [missingURL.standardizedFileURL])
        #expect(!fileManager.fileExists(atPath: settingsURL.path))
        #expect(!fileManager.fileExists(atPath: profilesURL.path))
    }

    @Test
    func remoteResetRestoresEarlierRemovalsWhenALaterStepFails() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let settingsURL = directory.appendingPathComponent("settings.json")
        let profilesURL = directory.appendingPathComponent("agents.json")
        let settingsData = Data("settings".utf8)
        let profilesData = Data("profiles".utf8)
        try settingsData.write(to: settingsURL)
        try profilesData.write(to: profilesURL)

        #expect(throws: CancellationError.self) {
            try ZenCODESetupRunner.resetRemoteConfiguration(
                fileManager: fileManager,
                configurationURLs: [settingsURL, profilesURL],
                removalCheckpoint: { completedRemovals in
                    if completedRemovals == 1 { throw CancellationError() }
                }
            )
        }

        #expect(try Data(contentsOf: settingsURL) == settingsData)
        #expect(try Data(contentsOf: profilesURL) == profilesData)
    }

    // MARK: - Telegram Threaded mode status
    //
    // `zen --setup` only reports the flag Telegram returns from `getMe`: the tests
    // stub the Bot API transport, capture the lines through the `write` seam and
    // never touch the real support directory or the network.

    private static let threadedEnabledLine =
        "Threaded mode: enabled — each ZenCODE session gets its own Telegram topic."
    private static let threadedDisabledLine =
        "Threaded mode: disabled — all sessions share the chat. "
        + "To get one topic per session, open @BotFather › your bot › Bot Settings "
        + "and enable Threaded mode."
    private static let threadedCases: [(flag: Bool?, line: String)] = [
        (true, threadedEnabledLine),
        (false, threadedDisabledLine),
        (nil, threadedDisabledLine)
    ]

    private static let enableLabel = "Enable Telegram remote control?"
    private static let replaceLabel = "Replace stored Telegram bot token and pairing?"

    private static let keptTelegram = pairedTelegram(token: "stored-token")

    /// What a completed pairing writes, as the stub chat "Ada" (id 42) links it.
    private static func pairedTelegram(token: String) -> AgentTelegramSettingsManifest {
        AgentTelegramSettingsManifest(
            enabled: true,
            botToken: token,
            linkedChatID: 42,
            linkedChatTitle: "Ada",
            ownerUserID: 42,
            routes: [AgentTelegramRouteManifest(roomID: "default")]
        )
    }

    @Test
    func pairingPrintsTheThreadedModeStatusFromGetMeBeforeTheLink() async throws {
        var writtenManifests = Set<Data>()
        for (flag, line) in Self.threadedCases {
            let output = SetupOutputBuffer()
            let transport = ThreadedModeWireTransport(getMe: .reports(flag), output: output)

            let telegram = try await ZenCODESetupRunner.pairTelegram(
                botToken: "token",
                transport: transport,
                write: { output.append($0) }
            )

            let text = output.text
            let threaded = try #require(text.range(of: line + "\n"))
            let pairing = try #require(text.range(of: "Telegram pairing:"))
            #expect(threaded.upperBound <= pairing.lowerBound)
            #expect(text.components(separatedBy: "Threaded mode:").count == 2)
            #expect(transport.requestPaths.filter { $0.hasSuffix("/getMe") }.count == 1)

            // The flag never reaches what setup writes to settings.json.
            #expect(telegram == Self.pairedTelegram(token: "token"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            writtenManifests.insert(
                try encoder.encode(AgentSettingsManifest(models: [], telegram: telegram))
            )
        }
        #expect(writtenManifests.count == 1)
    }

    @Test
    func keptPairingPrintsTheStatusFromAPlainGetMeAndChangesNothing() async throws {
        for (flag, line) in Self.threadedCases {
            let output = SetupOutputBuffer()
            let transport = ThreadedModeWireTransport(getMe: .reports(flag), output: output)
            var asked: [String] = []

            let result = try await ZenCODESetupRunner.promptTelegramSettings(
                existingSettings: Self.keptTelegram,
                transport: transport,
                confirm: { label, _ in
                    asked.append(label)
                    return label == Self.enableLabel
                },
                write: { output.append($0) }
            )

            #expect(result == Self.keptTelegram)
            #expect(asked == [Self.enableLabel, Self.replaceLabel])
            #expect(output.text == line + "\n")
            // Only `getMe` with the stored token: no `deleteWebhook`, no update
            // polling, no pairing grant.
            #expect(transport.requestPaths == ["/botstored-token/getMe"])
        }
    }
}

/// Lines `zen --setup` writes, captured through the `write` seam.
private final class SetupOutputBuffer: Sendable {
    private let storage = Mutex("")

    func append(_ text: String) {
        storage.withLock { $0 += text }
    }

    var text: String { storage.withLock { $0 } }
}

private struct ThreadedModeFixtureError: Error {}

/// Bot API fake for `zen --setup`: `getMe` answers as configured, `deleteWebhook`
/// and `sendMessage` succeed, and `getUpdates` delivers the `/start` deep link
/// payload that setup printed into `output`, so a pairing completes at once.
/// Any other method fails the test run. Every request path is recorded.
private final class ThreadedModeWireTransport: TelegramHTTPTransport, Sendable {
    enum GetMe: Sendable {
        case reports(Bool?)
        case httpError(Int)
        case undecodable
        case unreachable
    }

    private let getMe: GetMe
    private let output: SetupOutputBuffer
    private let paths = Mutex<[String]>([])

    init(getMe: GetMe, output: SetupOutputBuffer) {
        self.getMe = getMe
        self.output = output
    }

    var requestPaths: [String] { paths.withLock { $0 } }

    func send(
        url: URL,
        method: String,
        headers: [RemoteHTTPHeader],
        body: Data?,
        timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        paths.withLock { $0.append(url.path) }
        switch url.lastPathComponent {
        case "getMe":
            return try getMeResponse()
        case "deleteWebhook":
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "getUpdates":
            guard let payload = Self.pairingPayload(in: output.text) else {
                throw ThreadedModeFixtureError()
            }
            return (200, Data(
                #"""
                {"ok":true,"result":[{"update_id":1,"message":{"message_id":5,
                "from":{"id":42,"is_bot":false,"first_name":"Ada"},
                "chat":{"id":42,"type":"private","first_name":"Ada"},
                "text":"/start \#(payload)"}}]}
                """#.utf8
            ))
        case "sendMessage":
            return (200, Data(
                #"{"ok":true,"result":{"message_id":6,"chat":{"id":42,"type":"private"}}}"#.utf8
            ))
        default:
            throw ThreadedModeFixtureError()
        }
    }

    private func getMeResponse() throws -> (status: Int, body: Data) {
        switch getMe {
        case .reports(let flag):
            let field = flag.map { #","has_topics_enabled":\#($0)"# } ?? ""
            return (200, Data(
                #"{"ok":true,"result":{"id":9001,"is_bot":true,"first_name":"bot","username":"test_bot"\#(field)}}"#.utf8
            ))
        case .httpError(let status):
            return (status, Data(
                "{\"ok\":false,\"error_code\":\(status),\"description\":\"Unauthorized\"}".utf8
            ))
        case .undecodable:
            return (200, Data("not json".utf8))
        case .unreachable:
            throw URLError(.notConnectedToInternet)
        }
    }

    /// The payload of the `https://t.me/<bot>?start=<payload>` link in `text`.
    private static func pairingPayload(in text: String) -> String? {
        guard let marker = text.range(of: "?start=") else { return nil }
        let payload = text[marker.upperBound...].prefix { $0.isHexDigit }
        return payload.isEmpty ? nil : String(payload)
    }
}
