import Foundation
import Synchronization
import Testing
@testable import figma_tools_feature

@Suite
struct FigmaBrowserLauncherTests {
    private let url = URL(string: "http://127.0.0.1:53682/")!

    @Test
    func wslviewIsPreferredOverXdgOpen() {
        let command = FigmaBrowserLauncher.command(
            for: url,
            launchers: FigmaBrowserLauncher.linuxLaunchers,
            isExecutable: { _ in true }
        )
        #expect(command == FigmaBrowserLauncher.Command(
            executablePath: "/usr/bin/wslview",
            arguments: ["http://127.0.0.1:53682/"]
        ))
    }

    @Test
    func xdgOpenIsTheFallbackAndLocalInstallsAreChecked() {
        let system = FigmaBrowserLauncher.command(
            for: url,
            launchers: FigmaBrowserLauncher.linuxLaunchers,
            isExecutable: { $0 == "/usr/bin/xdg-open" || $0 == "/usr/local/bin/xdg-open" }
        )
        #expect(system?.executablePath == "/usr/bin/xdg-open")

        let local = FigmaBrowserLauncher.command(
            for: url,
            launchers: FigmaBrowserLauncher.linuxLaunchers,
            isExecutable: { $0 == "/usr/local/bin/xdg-open" }
        )
        #expect(local?.executablePath == "/usr/local/bin/xdg-open")
        #expect(local?.arguments == ["http://127.0.0.1:53682/"])
    }

    @Test
    func noCommandIsReturnedWithoutAnExecutableLauncher() {
        let command = FigmaBrowserLauncher.command(
            for: url,
            launchers: FigmaBrowserLauncher.linuxLaunchers,
            isExecutable: { _ in false }
        )
        #expect(command == nil)
    }

    @Test
    func macOSUsesOpenAndEachPlatformUsesItsOwnLaunchers() {
        let command = FigmaBrowserLauncher.command(
            for: url,
            launchers: FigmaBrowserLauncher.macOSLaunchers,
            isExecutable: { _ in true }
        )
        #expect(command?.executablePath == "/usr/bin/open")

        #if os(macOS)
        #expect(FigmaBrowserLauncher.platformLaunchers == FigmaBrowserLauncher.macOSLaunchers)
        #else
        #expect(FigmaBrowserLauncher.platformLaunchers == FigmaBrowserLauncher.linuxLaunchers)
        #endif
    }
}

@Suite
struct FigmaLoginRequestLimitTests {
    @Test
    func requestsAreReassembledAcrossChunks() throws {
        var reader = FigmaLoginHTTP.RequestReader()
        let first = "POST / HTTP/1.1\r\nHost: 127.0.0.1:5000\r\nContent-Length: 11\r\n\r\nstate="
        guard case .incomplete = reader.append(Data(first.utf8)) else {
            Issue.record("A request with a partial body must stay incomplete.")
            return
        }
        guard case let .request(request) = reader.append(Data("abc12".utf8)) else {
            Issue.record("The full body must complete the request.")
            return
        }
        #expect(request.method == "POST")
        #expect(FigmaLoginHTTP.parseFormURLEncoded(request.body)["state"] == "abc12")
    }

    @Test
    func requestsOverTheLimitAreRefusedBeforeBeingParsed() {
        #expect(FigmaLoginHTTP.maximumRequestSize == 64 * 1024)

        var reader = FigmaLoginHTTP.RequestReader(limit: 64)
        let prefix = "GET / HTTP/1.1\r\nX-Padding: "
        guard case .incomplete = reader.append(Data(prefix.utf8)) else {
            Issue.record("Headers without their terminator must stay incomplete.")
            return
        }
        // A complete request still counts against the limit as soon as it is too long.
        let overflow = String(repeating: "a", count: 64) + "\r\n\r\n"
        guard case .tooLarge = reader.append(Data(overflow.utf8)) else {
            Issue.record("More than the limit must be refused.")
            return
        }
    }

    @Test
    func aRequestExactlyAtTheLimitIsStillAccepted() {
        let raw = "GET / HTTP/1.1\r\n\r\n"
        var reader = FigmaLoginHTTP.RequestReader(limit: raw.utf8.count)
        guard case .request = reader.append(Data(raw.utf8)) else {
            Issue.record("A request of exactly the limit must be accepted.")
            return
        }
    }

    @Test
    func responsesAreCompleteHTTPMessagesThatAreNeverCached() throws {
        let response = FigmaLoginHTTP.Response.requestTooLarge
        let text = String(decoding: response.serialized(), as: UTF8.self)
        let (head, body) = try #require(text.components(separatedBy: "\r\n\r\n").splitFirst())
        #expect(head.hasPrefix("HTTP/1.1 413 Content Too Large\r\n"))
        #expect(head.contains("Content-Length: \(body.utf8.count)"))
        #expect(head.contains("Cache-Control: no-store"))
        #expect(head.contains("Connection: close"))
        #expect(head.contains("X-Frame-Options: DENY"))
        #expect(body == FigmaLoginPage.notFound)
    }
}

private extension Array where Element == String {
    /// The first part and the rest of the parts joined back: the header block and the body.
    func splitFirst() -> (String, String)? {
        guard let first else { return nil }
        return (first, dropFirst().joined(separator: "\r\n\r\n"))
    }
}

/// Holds a validation open until the test releases it.
private actor FigmaLoginGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private final class FigmaLoginRecorder: Sendable {
    private let entries = Mutex<[String]>([])

    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
    var all: [String] { entries.withLock { $0 } }
}

/// A transport without sockets, so the shared rules run deterministically.
private final class FigmaLoginStubTransport: FigmaLoginTransport {
    private let stops = Mutex(0)

    var stopCount: Int { stops.withLock { $0 } }

    func start(flow _: FigmaLoginFlow) async throws -> UInt16 { 4242 }
    func stop() { stops.withLock { $0 += 1 } }
}

private let acceptedCredential = FigmaStoredCredential(
    accessToken: "figd_good",
    accountHandle: "Gerardo",
    accountEmail: nil,
    signedInAt: Date(timeIntervalSince1970: 1_800_000_000)
)

private func makeRequest(
    method: String = "GET",
    path: String = "/",
    headers: [String: String] = [:],
    body: String = ""
) throws -> FigmaLoginHTTP.Request {
    var allHeaders = headers
    if method == "POST" { allHeaders["Content-Length"] = String(body.utf8.count) }
    var raw = "\(method) \(path) HTTP/1.1\r\n"
    for (name, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
        raw += "\(name): \(value)\r\n"
    }
    raw += "\r\n" + body
    return try #require(FigmaLoginHTTP.parse(Data(raw.utf8)))
}

private func respond(to flow: FigmaLoginFlow, _ request: FigmaLoginHTTP.Request) async -> FigmaLoginHTTP.Response {
    await withCheckedContinuation { continuation in
        flow.handle(request) { continuation.resume(returning: $0) }
    }
}

@Suite
struct FigmaLoginFlowRulesTests {
    private func makeFlow(
        validate: @escaping FigmaLoginFlow.Validator = { _ in .success(acceptedCredential) }
    ) -> FigmaLoginFlow {
        FigmaLoginFlow(reason: .notSignedIn, validate: validate)
    }

    @Test
    func onlyTheRootPathOnALoopbackHostServesThePage() async throws {
        let flow = makeFlow()

        let page = await respond(to: flow, try makeRequest(headers: ["Host": "127.0.0.1:5000"]))
        #expect(page.statusCode == 200)
        #expect(page.html.contains("value=\"\(flow.formToken)\""))

        let otherPath = await respond(to: flow, try makeRequest(path: "/other", headers: ["Host": "127.0.0.1:5000"]))
        #expect(otherPath.statusCode == 404)
        #expect(!otherPath.html.contains(flow.formToken))

        let rebinding = await respond(to: flow, try makeRequest(headers: ["Host": "evil.example:5000"]))
        #expect(rebinding.statusCode == 403)
        #expect(!rebinding.html.contains(flow.formToken))

        let unsupported = await respond(to: flow, try makeRequest(method: "PUT", headers: ["Host": "127.0.0.1:5000"]))
        #expect(unsupported.statusCode == 405)
    }

    @Test
    func postsNeedTheOneTimeTokenAndALoopbackOrigin() async throws {
        let calls = FigmaLoginRecorder()
        let flow = makeFlow { _ in
            calls.record("validate")
            return .success(acceptedCredential)
        }
        let loopback = ["Host": "127.0.0.1:5000", "Origin": "http://127.0.0.1:5000"]

        let wrongToken = await respond(to: flow, try makeRequest(method: "POST", headers: loopback, body: "state=nope&token=figd_good"))
        #expect(wrongToken.statusCode == 403)

        let missingToken = await respond(to: flow, try makeRequest(method: "POST", headers: loopback, body: "token=figd_good"))
        #expect(missingToken.statusCode == 403)

        let foreignOrigin = await respond(to: flow, try makeRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:5000", "Origin": "https://evil.example"],
            body: "state=\(flow.formToken)&token=figd_good"
        ))
        #expect(foreignOrigin.statusCode == 403)

        let foreignHost = await respond(to: flow, try makeRequest(
            method: "POST",
            headers: ["Host": "evil.example", "Origin": "http://127.0.0.1:5000"],
            body: "state=\(flow.formToken)&token=figd_good"
        ))
        #expect(foreignHost.statusCode == 403)

        #expect(calls.all.isEmpty)
    }

    @Test
    func onlyOneVerificationRunsAtATime() async throws {
        let gate = FigmaLoginGate()
        let flow = makeFlow { _ in
            await gate.wait()
            return .success(acceptedCredential)
        }
        let post = try makeRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:5000", "Origin": "http://127.0.0.1:5000"],
            body: "state=\(flow.formToken)&token=figd_good"
        )

        // The first submission claims the verification slot synchronously.
        let (answers, continuation) = AsyncStream.makeStream(of: FigmaLoginHTTP.Response.self)
        flow.handle(post) { response in
            continuation.yield(response)
            continuation.finish()
        }
        let second = await respond(to: flow, post)
        #expect(second.statusCode == 409)

        await gate.open()
        var iterator = answers.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.statusCode == 200)
        #expect(first?.html.contains("Connected as Gerardo.") == true)
    }
}

@Suite
struct FigmaLoginServerLifecycleTests {
    private func makeServer(
        transport: FigmaLoginStubTransport,
        validate: @escaping FigmaLoginServer.Validator = { _ in .success(acceptedCredential) }
    ) throws -> FigmaLoginServer {
        try FigmaLoginServer(reason: .manual, transport: transport, validate: validate)
    }

    @Test
    func theBrowserIsAnsweredBeforeTheWaiterIsReleased() async throws {
        let events = FigmaLoginRecorder()
        let transport = FigmaLoginStubTransport()
        let server = try makeServer(transport: transport)
        let waiter = Task {
            let credential = try await server.waitForResult(timeout: 30)
            events.record("released")
            return credential
        }

        let post = try makeRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:5000", "Origin": "http://127.0.0.1:5000"],
            body: "state=\(server.formToken)&token=figd_good"
        )
        let response: FigmaLoginHTTP.Response = await withCheckedContinuation { continuation in
            server.flow.handle(post) { response in
                // Runs before the flow releases the waiter, on the same thread.
                events.record("answered")
                continuation.resume(returning: response)
            }
        }
        #expect(response.statusCode == 200)

        let credential = try await waiter.value
        #expect(credential == acceptedCredential)
        #expect(events.all == ["answered", "released"])
    }

    @Test
    func stoppingCancelsTheWaiterAndRefusesLaterSubmissions() async throws {
        let transport = FigmaLoginStubTransport()
        let server = try makeServer(transport: transport)
        let waiter = Task { try await server.waitForResult(timeout: 30) }

        server.stop()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(transport.stopCount >= 1)

        let late = await respond(to: server.flow, try makeRequest(
            method: "POST",
            headers: ["Host": "127.0.0.1:5000", "Origin": "http://127.0.0.1:5000"],
            body: "state=\(server.formToken)&token=figd_good"
        ))
        #expect(late.statusCode == 409)
    }

    @Test
    func cancellingTheWaitingTaskStopsTheTransport() async throws {
        let transport = FigmaLoginStubTransport()
        let server = try makeServer(transport: transport)
        let waiter = Task { try await server.waitForResult(timeout: 30) }

        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(transport.stopCount >= 1)
    }

    @Test
    func theWaitEndsWithATimeoutAndStopsTheTransport() async throws {
        let transport = FigmaLoginStubTransport()
        let server = try makeServer(transport: transport)

        // The wait never lasts less than one second.
        await #expect(throws: FigmaToolsError.loginTimedOut) {
            try await server.waitForResult(timeout: 1)
        }
        #expect(transport.stopCount >= 1)
    }

    @Test
    func startDelegatesToTheTransport() async throws {
        let server = try makeServer(transport: FigmaLoginStubTransport())
        #expect(try await server.start() == 4242)
    }
}
