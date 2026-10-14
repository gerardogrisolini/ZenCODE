import Foundation
import Testing
@testable import ZenCODECore

@Suite("ChatGPT voice bridge", .serialized)
struct ChatGPTVoiceBridgeTests {
    static func command(_ name: String, id: String = UUID().uuidString, fields: [String: Any] = [:]) throws -> VoiceBridgeCommand {
        var value = fields; value["version"] = 1; value["id"] = id; value["command"] = name
        return try VoiceBridgeCommand.decode(JSONSerialization.data(withJSONObject: value))
    }
    static var identity: CodexAgentCredentials { .init(accessToken: "fixture-bearer", refreshToken: "fixture-refresh", expiresAt: Date().addingTimeInterval(3600), accountID: "fixture-account") }
    @Test func commandAllowlistAndFraming() throws {
        let value = try Self.command("open", fields: ["sdp": "v=0\r\n", "projects": ["/fixture"]])
        #expect(value.command == "open")
        for object: [String: Any] in [
            ["version": 1, "id": "one", "command": "input_audio.append", "audio": "AAAA"],
            ["version": 1, "id": "one", "command": "close", "token": "private"],
            ["version": 2, "id": "one", "command": "close"],
            ["version": 1, "id": "one", "command": "open", "sdp": "v=0", "projects": []]
        ] { #expect(throws: (any Error).self) { try VoiceBridgeCommand.decode(JSONSerialization.data(withJSONObject: object)) } }
        #expect(throws: (any Error).self) { try VoiceBridgeCommand.decode(Data(repeating: 65, count: 131_073)) }
        var framer = VoiceBridgeFramer()
        #expect(try framer.append(Data("{\"x\":".utf8)).isEmpty)
        #expect(try framer.append(Data("1}\n".utf8)).count == 1)
        try framer.finish()
        _ = try framer.append(Data("partial".utf8))
        #expect(throws: (any Error).self) { try framer.finish() }
    }
    @Test func openAcceptsMoreThan32Projects() throws {
        let projects = (0..<33).map { "/fixture/project-\($0)" }
        let value = try Self.command("open", fields: ["sdp": "v=0\r\n", "projects": projects])
        #expect(value.projects == projects)
    }
    @Test func openRetainsPathAndSDPLimits() throws {
        for fields: [String: Any] in [
            ["sdp": "v=0", "projects": ["relative/project"]],
            ["sdp": "v=0", "projects": ["/" + String(repeating: "a", count: 4096)]],
            ["sdp": "v=0", "projects": ["/" + String(repeating: "é", count: 2048)]],
            ["sdp": "invalid", "projects": ["/fixture"]],
            ["sdp": "v=0" + String(repeating: "a", count: 65_534), "projects": ["/fixture"]]
        ] {
            #expect(throws: VoiceBridgeFailure.invalidCommand) {
                try Self.command("open", fields: fields)
            }
        }
    }
    @Test func correctV3Shape() throws {
        let data = try ChatGPTVoiceBridge.sessionBody(sdp: "v=0\r\n", projects: ["/fixture"])
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(root["session"] as? [String: Any])
        #expect(session["model"] as? String == "gpt-live-1-codex")
        let audio = try #require(session["audio"] as? [String: Any])
        #expect((audio["output"] as? [String: Any])?["voice"] as? String == "cove")
        #expect(session["tools"] == nil)
    }
    @Test func authGuardAndNoRefresh() throws {
        #expect(throws: (any Error).self) { try ChatGPTVoiceBridge.validateCredentials(.init(accessToken: "x\r\ny", refreshToken: "fixture", expiresAt: Date().addingTimeInterval(3600), accountID: "account")) }
        #expect(throws: VoiceBridgeFailure.authExpired) { try ChatGPTVoiceBridge.validateCredentials(.init(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantPast, accountID: "account")) }
    }
    @Test(arguments: [401, 403, 429]) func rejectedWithoutFallback(status: Int) async throws {
        let transport = TestVoiceTransport(status: status), events = VoiceEvents()
        let session = ChatGPTVoiceBridge(transport: transport, credentials: { Self.identity }, output: { await events.add($0) })
        try await session.handle(Self.command("open", fields: ["sdp": "v=0\r\n", "projects": ["/fixture"]]))
        try await wait { await events.has("closed") }
        #expect(await transport.connectCount == 0)
        #expect(await transport.requests.count == 1)
        #expect(await events.codes().contains(ChatGPTVoiceBridge.httpCode(status)))
        await session.close()
    }
    @Test func authMissingNeverConnects() async throws {
        let transport = TestVoiceTransport(), events = VoiceEvents()
        let session = ChatGPTVoiceBridge(transport: transport, credentials: { throw VoiceBridgeFailure.authMissing }, output: { await events.add($0) })
        try await session.handle(Self.command("open", fields: ["sdp": "v=0", "projects": ["/fixture"]]))
        try await wait { await events.has("closed") }
        #expect(await transport.requests.isEmpty)
        #expect(await events.codes().contains("auth_missing"))
    }
    @Test func delegationDedupAndCleanup() async throws {
        let transport = TestVoiceTransport(), events = VoiceEvents()
        let session = ChatGPTVoiceBridge(transport: transport, credentials: { Self.identity }, output: { await events.add($0) })
        try await session.handle(Self.command("open", fields: ["sdp": "v=0", "projects": ["/fixture"]]))
        try await wait { await events.has("opened") }
        let event = Data(#"{"type":"delegation.created","item":{"id":"delegation_fixture","type":"delegation","target":"client","content":[{"type":"input_text","text":"fixture"}]}}"#.utf8)
        try await session.receiveEvent(event); try await session.receiveEvent(event)
        #expect(await events.count("delegation") == 1)
        try await session.handle(Self.command("delegationResult", fields: ["delegationID": "delegation_fixture", "text": "untrusted result"]))
        await #expect(throws: (any Error).self) { try await session.handle(Self.command("delegationResult", fields: ["delegationID": "delegation_fixture", "text": "replay"])) }
        await session.close()
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.last?.url.absoluteString == "https://api.openai.com/v1/realtime/calls/rtc_fixture/hangup")
        #expect(await transport.stopped)
        let output = await events.encoded()
        #expect(!output.contains("fixture-bearer")); #expect(!output.contains("fixture-account")); #expect(!output.contains("fixture-refresh"))
    }
    @Test func cancelCreateAfterHeadersStillHangsUp() async throws {
        let transport = TestVoiceTransport(slow: true), events = VoiceEvents()
        let session = ChatGPTVoiceBridge(transport: transport, credentials: { Self.identity }, output: { await events.add($0) })
        try await session.handle(Self.command("open", fields: ["sdp": "v=0", "projects": ["/fixture"]]))
        try await wait { await transport.headersSent }
        await session.close()
        #expect(await transport.requests.count == 2)
        #expect(await transport.connectCount == 0)
        #expect(await transport.stopped)
    }
    @Test func stalledSocketCloseDoesNotPreventHangup() async throws {
        let transport = TestVoiceTransport(slowClose: true), events = VoiceEvents()
        let session = ChatGPTVoiceBridge(transport: transport, credentials: { Self.identity }, output: { await events.add($0) })
        try await session.handle(Self.command("open", fields: ["sdp": "v=0", "projects": ["/fixture"]]))
        try await wait { await events.has("opened") }
        let start = ContinuousClock.now
        await session.close()
        #expect(ContinuousClock.now - start < .seconds(4))
        #expect(await transport.requests.count == 2)
        #expect(await transport.stopped)
    }
    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<200 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw VoiceBridgeFailure.timeout
    }
}
private actor VoiceEvents {
    var events: [VoiceBridgeEvent] = []
    func add(_ event: VoiceBridgeEvent) { events.append(event) }
    func has(_ type: String) -> Bool { events.contains { $0.type == type } }
    func count(_ type: String) -> Int { events.filter { $0.type == type }.count }
    func codes() -> [String] { events.compactMap(\.code) }
    func encoded() -> String { String(decoding: (try? JSONEncoder().encode(events)) ?? Data(), as: UTF8.self) }
}
private actor TestVoiceSocket: VoiceBridgeSocket {
    let slowClose: Bool
    init(slowClose: Bool = false) { self.slowClose = slowClose }
    var frames: [RemoteWebSocketFrame] = []
    func send(_ frame: RemoteWebSocketFrame) { frames.append(frame) }
    func receive() async throws -> RemoteWebSocketFrame? { try await Task.sleep(for: .seconds(60)); return nil }
    func close(code: UInt16, reason: String?) async throws { if slowClose { try await Task.sleep(for: .seconds(60)) } }
}
private actor TestVoiceTransport: VoiceBridgeTransport {
    var requests: [RemoteHTTPStreamingRequest] = []
    var stopped = false, headersSent = false
    var connectCount = 0
    let status: Int, slow: Bool, slowClose: Bool
    init(status: Int = 201, slow: Bool = false, slowClose: Bool = false) { self.status = status; self.slow = slow; self.slowClose = slowClose }
    func request(_ request: RemoteHTTPStreamingRequest, head: @escaping @Sendable (Int, RemoteHTTPHeaders) async -> Void) async throws -> VoiceBridgeHTTPResponse {
        requests.append(request)
        if request.url.path.hasSuffix("/hangup") { return .init(status: 200, body: Data()) }
        await head(status, .init([.init(name: "Location", value: "/v1/live/rtc_fixture")]))
        headersSent = true
        if slow { try await Task.sleep(for: .seconds(60)) }
        return .init(status: status, body: Data("v=0\r\n".utf8))
    }
    func connect(_ request: RemoteWebSocketRequest) async throws -> any VoiceBridgeSocket { connectCount += 1; return TestVoiceSocket(slowClose: slowClose) }
    func shutdown() { stopped = true }
}
