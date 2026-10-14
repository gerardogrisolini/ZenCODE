import Foundation
import Testing

struct ProtocolTests {
    @Test func framingAcrossChunksAndLimits() throws {
        var framer = LineFramer(limit: 8)
        let partial = try framer.append(Data("{\"a\":".utf8))
        #expect(partial.isEmpty)
        let lines = try framer.append(Data("1}\n{}\n".utf8))
        #expect(lines.count == 2)
        #expect(try JSON.parse(lines[0])["a"].integer == 1)
        #expect(throws: VoiceError.self) { try framer.append(Data(repeating: 65, count: 9)) }
    }
    @Test func exactNewHumanTurnOnly() {
        let now = Date(timeIntervalSince1970: 1000)
        var challenge = PermissionChallenge(nonce: "sole mare luna", now: now)
        #expect(!challenge.accepts(challenge.phrase, item: "old", now: now))
        #expect(!challenge.accepts(challenge.phrase, item: "model-call", now: now))
        challenge.eligibleItems.insert("fresh-microphone-item")
        #expect(challenge.accepts("Autorizzo una volta sole mare luna.", item: "fresh-microphone-item", now: now.addingTimeInterval(2)))
        #expect(!challenge.accepts("Sì", item: "fresh-microphone-item", now: now))
        #expect(!challenge.accepts(challenge.phrase + " no", item: "fresh-microphone-item", now: now))
        #expect(!challenge.accepts(challenge.phrase, item: "fresh-microphone-item", now: now.addingTimeInterval(90)))
        let replacement = PermissionChallenge(nonce: "altra frase", now: now)
        #expect(!replacement.accepts(challenge.phrase, item: "fresh-microphone-item", now: now))
    }
    @Test func echoAndLateEventsNeverArmPermission() {
        let now = Date(timeIntervalSince1970: 1000)
        var challenge = PermissionChallenge(nonce: "sole mare luna", now: now)
        challenge.microphoneWatermark = 5000
        challenge.beginTurn(item: "echo", audioStart: 2000, announcementCompleted: true, playbackDrained: true, quietSeconds: 2)
        challenge.beginTurn(item: "playing", audioStart: 6000, announcementCompleted: true, playbackDrained: false, quietSeconds: 2)
        challenge.beginTurn(item: "not-announced", audioStart: 6000, announcementCompleted: false, playbackDrained: true, quietSeconds: 2)
        challenge.beginTurn(item: "too-soon", audioStart: 6000, announcementCompleted: true, playbackDrained: true, quietSeconds: 0.9)
        #expect(challenge.eligibleItems.isEmpty)
        challenge.beginTurn(item: "human", audioStart: 6100, announcementCompleted: true, playbackDrained: true, quietSeconds: 2)
        #expect(challenge.accepts(challenge.phrase, item: "human", now: now))
    }
    @Test @MainActor func gaConfigurationUsesAudioAndNoPermissionTool() {
        let session = RealtimeClient.configuration(projects: ["/tmp/project"])["session"]
        #expect(session["type"].text == "realtime")
        #expect(session["audio"]["input"]["format"]["rate"].integer == 24000)
        #expect(session["audio"]["input"]["transcription"]["model"].text == "gpt-4o-mini-transcribe")
        #expect(session["tools"].values.count == 1)
        #expect(!session["tools"].serialized.contains("allow_once"))
        #expect(session["input_audio_format"] == .null)
    }
    @Test func checkoutCanonicalization() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        #expect(try Settings.canonicalProject(dir.appendingPathComponent("Sources").path) == dir.resolvingSymlinksInPath().path)
    }
    @Test func jsonRoundTripPreservesStringIDsAndToolMetadata() throws {
        let value: JSON = ["jsonrpc": "2.0", "id": "permission-1", "params": ["toolCall": ["kind": "execute", "_meta": ["toolName": "local.exec"]]]]
        #expect(try JSON.parse(value.encoded()) == value)
    }
}

struct ACPFixtureTests {
    @Test @MainActor func fakeProcessHandshakePromptAndPermission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-zen")
        // POSIX shell is sufficient: consume ordered newline frames and emit deterministic fixtures.
        let script = #"""
        #!/bin/sh
        IFS= read -r initialize
        # Fragment a small frame, keeping stdout open while awaiting the next request.
        printf '%s' '{"jsonrpc":"2.0","id":1,"result":'
        sleep 0.05
        printf '%s\n' '{"protocolVersion":1}}'
        IFS= read -r session
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"sessionId":"fixture-session"}}'
        IFS= read -r prompt
        printf '%s\n' '{"jsonrpc":"2.0","id":"permission-fixture","method":"session/request_permission","params":{"sessionId":"fixture-session","options":[{"optionId":"allow_once","kind":"allow_once"}],"toolCall":{"kind":"execute","_meta":{"toolName":"local.exec"}}}}'
        IFS= read -r decision
        case "$decision" in
          *'"optionId":"allow_once"'*) ;;
          *) exit 3 ;;
        esac
        printf '%s\n' '{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"fixture complete"}}}}'
        printf '%s\n' '{"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}'
        while IFS= read -r line; do :; done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = ACPClient()
        defer { client.shutdown() }
        var permissionSeen = false
        client.permission = { id, params in
            permissionSeen = true
            #expect(params["toolCall"]["_meta"]["toolName"].text == "local.exec")
            try? client.respond(id: id, option: "allow_once")
        }
        try await client.start(executable: executable.path, cwd: directory.path)
        #expect(client.sessionID == "fixture-session")
        let result = try await client.prompt("fixture only")
        #expect(permissionSeen)
        #expect(result.contains("fixture complete"))
        #expect(!client.busy)
        #expect(client.process.isRunning)
    }
}

struct HardeningRegressionTests {
    @Test func cloudCompletionCannotProveDiscardedPlayback() throws {
        var playback = PlaybackReceipt()
        let token = try playback.append(item: "announcement", frames: 24_000)
        var receipt = AnnouncementReceipt()
        var challenge = PermissionChallenge(nonce: "sole mare luna")
        receipt.spoken(text: challenge.phrase, phrase: challenge.phrase, response: "r1", item: "announcement")
        receipt.done(response: "r1", success: true)
        #expect(!receipt.heard(playback: playback))
        let cutoff = playback.interrupt()
        #expect(cutoff?.1 == 0)
        receipt.interrupt()
        playback.completed(frames: 24_000, token: token) // stale dataPlayedBack
        receipt.done(response: "r1", success: true) // stale cloud completion
        challenge.beginTurn(item: "human", audioStart: 9000, announcementCompleted: receipt.heard(playback: playback), playbackDrained: playback.drained, quietSeconds: 2)
        #expect(!challenge.accepts(challenge.phrase, item: "human"))
    }

    @Test func actualPlaybackArmsOnlyOneFreshTurn() throws {
        var playback = PlaybackReceipt()
        let token = try playback.append(item: "a", frames: 2400)
        var receipt = AnnouncementReceipt()
        var challenge = PermissionChallenge(nonce: "sole mare luna")
        receipt.spoken(text: challenge.phrase, phrase: challenge.phrase, response: "r", item: "a")
        receipt.done(response: "old", success: true)
        playback.completed(frames: 2400, token: token)
        #expect(!receipt.heard(playback: playback))
        receipt.done(response: "r", success: true)
        #expect(receipt.heard(playback: playback))
        if receipt.heard(playback: playback) { challenge.microphoneWatermark = 5000 }
        challenge.beginTurn(item: "echo", audioStart: 4000, announcementCompleted: receipt.heard(playback: playback), playbackDrained: playback.drained, quietSeconds: 2)
        #expect(!challenge.accepts(challenge.phrase, item: "echo"))
        challenge.beginTurn(item: "human", audioStart: 5100, announcementCompleted: receipt.heard(playback: playback), playbackDrained: playback.drained, quietSeconds: 2)
        #expect(challenge.accepts(challenge.phrase, item: "human"))
        challenge.beginTurn(item: "next", audioStart: 5200, announcementCompleted: false, playbackDrained: true, quietSeconds: 0)
        #expect(!challenge.accepts(challenge.phrase, item: "human"))
        #expect(!challenge.accepts(challenge.phrase, item: "next"))
    }

    @Test func bargeInDropsLateAudioAndPreservesPlayedOffset() throws {
        var barrier = ResponseBarrier()
        var playback = PlaybackReceipt()
        barrier.created("old")
        let first = try playback.append(item: "item", frames: 2400)
        playback.completed(frames: 2400, token: first)
        _ = try playback.append(item: "item", frames: 2400)
        barrier.interrupt()
        let interruptedPlayback = playback.interrupt()
        #expect(interruptedPlayback?.1 == 100)
        if barrier.accepts("old") { _ = try playback.append(item: "item", frames: 2400) }
        #expect(playback.scheduled == 0)
        barrier.created("new")
        let oldDone = barrier.done("old")
        #expect(!oldDone)
        #expect(barrier.accepts("new"))
        #expect(!barrier.accepts("old"))
        barrier.interrupt() // before first delta of new response
        #expect(!barrier.accepts("new"))
        barrier = ResponseBarrier() // session epoch reset
        #expect(!barrier.accepts("new"))
    }

    @Test func closingRejectsActivationAndInFlightContinuation() throws {
        var lifecycle = VoiceLifecycle()
        let activated = lifecycle.activate()
        let token = try #require(activated)
        #expect(lifecycle.permits(token))
        lifecycle.deactivate()
        #expect(lifecycle.permitsAcceptedWork) // Disattiva does not cancel accepted ACP work
        #expect(!lifecycle.permits(token))
        let reactivated = lifecycle.activate()
        let next = try #require(reactivated)
        let closed = lifecycle.close()
        #expect(closed)
        #expect(!lifecycle.permitsAcceptedWork) // start suspended at handshake cannot prompt
        #expect(!lifecycle.permits(next))
        let rejectedActivation = lifecycle.activate()
        #expect(rejectedActivation == nil)
        let closedAgain = lifecycle.close()
        #expect(!closedAgain)
        lifecycle.deactivate()
        #expect(lifecycle.closing)
    }
}

struct AudioOrderingRegressionTests {
    @Test func interruptedPendingCreationCannotAdmitAudio() {
        var barrier = ResponseBarrier()
        barrier.requested("local-1")
        #expect(barrier.responding)
        barrier.interrupt()
        let acceptedLate = barrier.created("cancelled", request: "local-1")
        #expect(!acceptedLate)
        #expect(!barrier.accepts("cancelled"))
        barrier.speechStopped()
        let acceptedVAD = barrier.created("human-next")
        #expect(acceptedVAD)
        let lateDone = barrier.done("cancelled")
        #expect(!lateDone)
        #expect(barrier.responding)
        #expect(barrier.accepts("human-next"))
    }

    @Test func lateLocalCreationCannotReplaceNewVADResponse() {
        var barrier = ResponseBarrier()
        barrier.requested("local-1")
        barrier.interrupt()
        barrier.speechStopped()
        barrier.created("vad")
        let acceptedLate = barrier.created("late-local", request: "local-1")
        #expect(!acceptedLate)
        #expect(!barrier.accepts("late-local"))
        let lateDone = barrier.done("late-local")
        #expect(!lateDone)
        #expect(barrier.accepts("vad"))
        let vadDone = barrier.done("vad")
        #expect(vadDone)
        #expect(!barrier.responding)
        barrier.requested("local-2")
        let acceptedNew = barrier.created("fresh-local", request: "local-2")
        #expect(acceptedNew)
        #expect(barrier.accepts("fresh-local"))
    }

    @Test func oldDoneCannotReleaseExpectedVADTurn() {
        var barrier = ResponseBarrier()
        barrier.created("old")
        barrier.interrupt()
        barrier.speechStopped()
        let oldDone = barrier.done("old")
        #expect(oldDone)
        #expect(barrier.responding)
        barrier.created("vad")
        #expect(barrier.accepts("vad"))
    }

    @Test func toolFollowUpWaitsForRealPlaybackDrainExactlyOnce() throws {
        var barrier = ResponseBarrier()
        var playback = PlaybackReceipt()
        var followUp = FollowUpGate()
        barrier.created("checking")
        let audioToken = try playback.append(item: "checking-item", frames: 2400)
        let cloudDone = barrier.done("checking")
        #expect(cloudDone)
        followUp.request(from: followUp.epoch) // fast tool output after response.done
        let premature = followUp.take(responding: barrier.responding, playbackDrained: playback.drained)
        #expect(!premature)
        #expect(playback.item == "checking-item")
        playback.completed(frames: 1200, token: audioToken)
        let partial = followUp.take(responding: barrier.responding, playbackDrained: playback.drained)
        #expect(!partial)
        playback.completed(frames: 1200, token: audioToken) // dataPlayedBack, not cloud completion
        let drained = followUp.take(responding: barrier.responding, playbackDrained: playback.drained)
        #expect(drained)
        let duplicateWake = followUp.take(responding: barrier.responding, playbackDrained: playback.drained)
        #expect(!duplicateWake)
        barrier.requested("follow-up")
        barrier.created("result", request: "follow-up")
        _ = try playback.append(item: "result-item", frames: 2400)
        #expect(playback.item == "result-item")
        #expect(barrier.accepts("result"))
    }

    @Test func interruptionInvalidatesQueuedAndInFlightToolFollowUps() throws {
        var playback = PlaybackReceipt()
        var followUp = FollowUpGate()
        let audioToken = try playback.append(item: "old", frames: 2400)
        let toolToken = followUp.epoch
        followUp.request(from: toolToken)
        followUp.interrupt()
        _ = playback.interrupt()
        playback.completed(frames: 2400, token: audioToken)
        followUp.request(from: toolToken) // tool completed after barge-in
        let stale = followUp.take(responding: false, playbackDrained: playback.drained)
        #expect(!stale)
        #expect(playback.scheduled == 0)
        followUp.request(from: followUp.epoch)
        let blockedByVAD = followUp.take(responding: true, playbackDrained: playback.drained)
        #expect(!blockedByVAD)
        let fresh = followUp.take(responding: false, playbackDrained: playback.drained)
        #expect(fresh)
    }
}

struct SharedConfigurationTests {
    private static let providerID = "AAAAAAAA-1111-2222-3333-444444444444"
    private static let now = Date(timeIntervalSinceReferenceDate: 1000)

    private func manifest(subscription: Bool = true) -> [String: Any] {
        [
            "version": 13,
            "selected": ["modelID": "selected-binding"],
            "models": [["id": "selected-binding", "modelID": "different-chat-model", "providerID": Self.providerID]],
            "providers": [[
                "id": Self.providerID,
                "baseURL": subscription ? "chatgpt://subscription" : "https://api.openai.com/v1",
                "providerProfileID": "openai",
                "protocolProfileID": subscription ? "openai.chatgpt-subscription" : "openai.responses",
                "authPolicy": subscription ? "chatgpt_subscription" : "api_key_required"
            ]],
            "remoteAPIKeysByProviderID": [Self.providerID.lowercased(): "fixture-openai-key"],
            "chatGPTSubscriptionCredentials": [
                "accessToken": "fixture-subscription-token",
                "accountID": "fixture-account",
                "expiresAt": 5000
            ]
        ]
    }

    private func resolve(_ value: [String: Any]) throws -> VoiceConnection {
        try ZenCODEConfiguration.connection(from: JSONSerialization.data(withJSONObject: value), now: Self.now)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func subscriptionUsesSelectedBindingNotModelNameOrFirstProvider() throws {
        var value = manifest()
        var models = try #require(value["models"] as? [[String: Any]])
        models.insert(["id": "other-binding", "modelID": "selected-binding"], at: 0)
        value["models"] = models
        var providers = try #require(value["providers"] as? [[String: Any]])
        providers.insert([
            "id": "BBBBBBBB-1111-2222-3333-444444444444", "baseURL": "https://example.invalid/v1",
            "providerProfileID": "openrouter", "protocolProfileID": "openai.chat-completions", "authPolicy": "api_key_required"
        ], at: 0)
        value["providers"] = providers
        #expect(try resolve(value).provider == .chatGPTSubscription)
    }

    @Test func apiUsesKeyOfSelectedProviderAndDoesNotPersistIt() throws {
        let connection = try resolve(manifest(subscription: false))
        guard case .api(let key) = connection else {
            Issue.record("Expected OpenAI API connection")
            return
        }
        #expect(key == "fixture-openai-key")
        let local = String(decoding: try JSONEncoder().encode(Settings(projects: ["/fixture"])), as: UTF8.self)
        #expect(!local.contains(key))
        #expect(!local.contains("provider"))
    }

    @Test(arguments: ["missingSelection", "missingModel", "missingProvider", "duplicateModel", "duplicateProvider", "localModel"])
    func incompleteOrAmbiguousSelectionNeverFallsBack(scenario: String) throws {
        var value = manifest()
        switch scenario {
        case "missingSelection": value.removeValue(forKey: "selected")
        case "missingModel": value["selected"] = ["modelID": "unknown"]
        case "missingProvider": value["providers"] = []
        case "duplicateModel":
            let models = try #require(value["models"] as? [[String: Any]])
            value["models"] = models + models
        case "duplicateProvider":
            let providers = try #require(value["providers"] as? [[String: Any]])
            value["providers"] = providers + providers
        default: value["models"] = [["id": "selected-binding"]]
        }
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test(arguments: ["missing", "emptyToken", "emptyAccount", "expired", "nearlyExpired"])
    func invalidSubscriptionLoginNeverFallsBackToAPI(scenario: String) throws {
        var value = manifest()
        var login = try #require(value["chatGPTSubscriptionCredentials"] as? [String: Any])
        switch scenario {
        case "emptyToken": login["accessToken"] = " "
        case "emptyAccount": login["accountID"] = ""
        case "expired": login["expiresAt"] = 999
        case "nearlyExpired": login["expiresAt"] = 1060
        default: break
        }
        value["chatGPTSubscriptionCredentials"] = scenario == "missing" ? nil : login
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test(arguments: ["", " ", "fixture\r\ninjected-header", "fixture key"])
    func invalidAPIKeyIsRejected(key: String) throws {
        var value = manifest(subscription: false)
        value["remoteAPIKeysByProviderID"] = [Self.providerID.lowercased(): key]
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test func missingAPIKeyNeverUsesSubscriptionCredentials() throws {
        var value = manifest(subscription: false)
        value.removeValue(forKey: "remoteAPIKeysByProviderID")
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test(arguments: [
        "https://openrouter.ai/api/v1", "http://api.openai.com/v1", "https://api.openai.com.evil.invalid/v1",
        "https://api.openai.com:444/v1", "https://user@api.openai.com/v1", "https://api.openai.com/v1?key=fixture",
        "https://api.openai.com/custom"
    ])
    func incompatibleEndpointsNeverReceiveOpenAIKey(baseURL: String) throws {
        var value = manifest(subscription: false)
        var providers = try #require(value["providers"] as? [[String: Any]])
        providers[0]["baseURL"] = baseURL
        value["providers"] = providers
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test func unsupportedProviderDoesNotSelectAnAvailableSubscription() throws {
        var value = manifest(subscription: false)
        var providers = try #require(value["providers"] as? [[String: Any]])
        providers[0]["providerProfileID"] = "deepseek"
        value["providers"] = providers
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test func connectionFileIsRequiredAndReloadedEachTime() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        #expect(throws: VoiceError.self) { try ZenCODEConfiguration.loadConnection(directory: directory, now: Self.now) }
        try JSONSerialization.data(withJSONObject: manifest()).write(to: file)
        #expect(try ZenCODEConfiguration.loadConnection(directory: directory, now: Self.now).provider == .chatGPTSubscription)
        try Data("invalid-json-fixture-secret".utf8).write(to: file)
        let error = #expect(throws: VoiceError.self) { try ZenCODEConfiguration.loadConnection(directory: directory, now: Self.now) }
        #expect(error?.localizedDescription.contains("fixture-secret") == false)
        try FileManager.default.removeItem(at: file)
        #expect(throws: VoiceError.self) { try ZenCODEConfiguration.loadConnection(directory: directory, now: Self.now) }
    }

    @Test func unsupportedSettingsVersionIsRejected() throws {
        var value = manifest()
        value["version"] = 999
        #expect(throws: VoiceError.self) { try resolve(value) }
    }

    @Test func projectsMergeBinaryPlistSessionIndexAndSavedSelectionByCheckout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let checkout = directory.appendingPathComponent("checkout")
        let nested = checkout.appendingPathComponent("Sources")
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: checkout.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)
        let plist: [String: Any] = ["version": 1, "projects": [["name": "Registered checkout", "path": nested.path]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: directory.appendingPathComponent("ui-working-folders.plist"))
        let sessions: [String: Any] = ["version": 1, "sessions": [
            ["projectPath": checkout.path], ["projectPath": alias.path], ["projectPath": other.path],
            ["projectPath": "relative/path"], ["projectPath": directory.appendingPathComponent("missing").path]
        ]]
        try JSONSerialization.data(withJSONObject: sessions).write(to: directory.appendingPathComponent("sessions.json"))
        let projects = try ZenCODEConfiguration.loadProjects(directory: directory, including: [checkout.path])
        #expect(projects.count == 2)
        #expect(Set(projects.map(\.path)) == [checkout.resolvingSymlinksInPath().path, other.resolvingSymlinksInPath().path])
        #expect(projects.first { $0.path == checkout.resolvingSymlinksInPath().path }?.name == "Registered checkout")
    }

    @Test func sessionIndexAloneDiscoversProjectsWithoutAuthorizingThem() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let index: [String: Any] = ["version": 1, "sessions": [["projectPath": directory.path]]]
        try JSONSerialization.data(withJSONObject: index).write(to: directory.appendingPathComponent("sessions.json"))
        let projects = try ZenCODEConfiguration.loadProjects(directory: directory)
        #expect(projects.map(\.path) == [directory.resolvingSymlinksInPath().path])
        #expect(Settings().projects.isEmpty)
    }

    @Test func missingProjectIndexesPreserveExistingSelectionAndInvalidIndexIsReported() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(try ZenCODEConfiguration.loadProjects(directory: directory).isEmpty)
        #expect(try ZenCODEConfiguration.loadProjects(directory: directory, including: [directory.path]).count == 1)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("sessions.json"))
        #expect(throws: VoiceError.self) { try ZenCODEConfiguration.loadProjects(directory: directory) }
    }

    @Test func onlySelectedProjectsArePersistedAndEmptySelectionDisablesActivation() throws {
        let suite = "ZenVoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(Settings.load(defaults: defaults).projects.isEmpty)
        try Settings(projects: ["/chosen"]).save(defaults: defaults)
        #expect(Settings.load(defaults: defaults).projects == ["/chosen"])
        let empty = try Settings().validated(requiresProjects: false)
        try empty.save(defaults: defaults)
        #expect(Settings.load(defaults: defaults).projects.isEmpty)
        #expect(throws: VoiceError.self) { try empty.validated() }
    }

    @Test func moreThanThirtyTwoProjectsAreAllowed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let projects = try (0..<33).map { index in
            let project = directory.appendingPathComponent("project-\(index)")
            try FileManager.default.createDirectory(at: project.appendingPathComponent(".git"), withIntermediateDirectories: true)
            return project.resolvingSymlinksInPath().path
        }
        let settings = try Settings(projects: projects).validated()
        #expect(settings.projects == projects.sorted())
        #expect(throws: VoiceError.self) { try Settings(projects: projects + ["relative/path"]).validated() }
    }
}

struct SubscriptionTests {
    @Test func bridgeTextLimitPreservesUnicodeByteBudget() {
        let value = String(repeating: "città 👩🏽‍💻 ", count: 4000)
        let bounded = VoiceTextLimit.truncate(value, bytes: 12_000)
        #expect(bounded.utf8.count <= 12_000)
        #expect(value.hasPrefix(bounded))
        #expect(String(data: Data(bounded.utf8), encoding: .utf8) == bounded)
        #expect(VoiceTextLimit.truncate("👩🏽‍💻", bytes: 1).isEmpty)
    }
    @Test func oldSettingsPreserveOnlyAllowedProjects() throws {
        let data = Data(#"{"executable":"/bin/echo","projects":["/fixture"],"provider":"api","cloudConsent":true,"subscriptionCloudConsent":true}"#.utf8)
        let value = try JSONDecoder().decode(Settings.self, from: data)
        #expect(value.projects == ["/fixture"])
        #expect(Settings.executable == "/usr/local/bin/zen")
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        #expect(Set(encoded.keys) == ["projects"])
    }
    @Test func explicitPermissionCannotCrossClientRequestOrActivation() {
        let client = UUID(), epoch = UUID(), now = Date()
        let fence = ExplicitPermissionFence(client: client, request: .number(7), activation: epoch, deadline: now.addingTimeInterval(90))
        #expect(fence.accepts(client: client, request: .number(7), activation: epoch, choice: "allow_once", now: now))
        #expect(fence.accepts(client: client, request: .number(7), activation: epoch, choice: "deny", now: now))
        #expect(!fence.accepts(client: UUID(), request: .number(7), activation: epoch, choice: "allow_once", now: now))
        #expect(!fence.accepts(client: client, request: .number(8), activation: epoch, choice: "allow_once", now: now))
        #expect(!fence.accepts(client: client, request: .number(7), activation: UUID(), choice: "allow_once", now: now))
        #expect(!fence.accepts(client: client, request: .number(7), activation: epoch, choice: "allow_always", now: now))
        #expect(!fence.accepts(client: client, request: .number(7), activation: epoch, choice: "allow_once", now: now.addingTimeInterval(90)))
    }
    @Test func subscriptionDelegationStrictProjectAndDedup() {
        var gate = SubscriptionDelegationGate()
        let request = #"{"action":"start","project":"/fixture","prompt":"test"}"#
        #expect(gate.accept(id: "one", text: request, projects: ["/fixture"]) != nil)
        #expect(gate.accept(id: "one", text: request, projects: ["/fixture"]) == nil)
        #expect(gate.accept(id: "two", text: request, projects: ["/other"]) == nil)
        #expect(gate.accept(id: "three", text: #"{"action":"allow_always","project":"/fixture","prompt":""}"#, projects: ["/fixture"]) == nil)
        #expect(gate.accept(id: "four", text: "Please start a task", projects: ["/fixture"]) == nil)
        #expect(gate.accept(id: "five", text: #"{"action":"start","project":"/fixture","prompt":"test","approval":true}"#, projects: ["/fixture"]) == nil)
    }
    @Test func remoteICECannotTargetPrivateServices() {
        #expect(SubscriptionSDPPolicy.publicAddress("8.8.8.8"))
        for address in ["127.0.0.1", "10.0.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "peer.local"] {
            #expect(!SubscriptionSDPPolicy.publicAddress(address))
        }
        #expect(!SubscriptionSDPPolicy.accepts("v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=fingerprint:sha-256 test\r\na=candidate:1 1 udp 1 127.0.0.1 9000 typ host\r\n"))
    }
    @Test @MainActor func missingLoginBridgeNeverFallsBackToAPI() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("voice-stub")
        let script = """
        #!/bin/sh
        printf '{"version":1,"type":"ready"}\\n'
        while IFS= read -r line; do
          printf '{"version":1,"type":"error","code":"auth_missing"}\\n'
          break
        done
        """
        try Data(script.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let bridge = VoiceBridgeClient()
        var message = ""
        bridge.onFailure = { message = $0 }
        try await bridge.start(executable: file.path)
        await #expect(throws: (any Error).self) { try await bridge.open(sdp: "v=0", projects: ["/fixture"]) }
        #expect(message.contains("Login ChatGPT assente"))
        #expect(message.contains("Nessun fallback API"))
        await bridge.stop()
    }
}
