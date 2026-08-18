import FeatureKit
import Foundation
@testable import WebToolsFeature
import Testing

/// Deterministic resolver used to exercise the network request policy without
/// touching the real DNS stack.
struct StaticWebHostResolver: WebHostResolving {
    let addressesByHost: [String: [String]]

    func resolve(host: String) throws -> [String] {
        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let addresses = addressesByHost[normalized] ?? addressesByHost[host] else {
            throw WebNetworkGuardError.unresolvedHost(host)
        }
        return addresses
    }
}

@Suite
struct WebURLPolicyTests {
    @Test
    func allowsPublicDestinations() throws {
        let policy = WebURLPolicy(environment: [:])

        #expect(try policy.validate("https://example.com/path?q=1").host == "example.com")
        #expect(try policy.validate("http://93.184.216.34/").host == "93.184.216.34")
        #expect(try policy.validate("https://[2606:2800:220:1:248:1893:25c8:1946]/").host != nil)
    }

    @Test
    func rejectsNonPublicDestinations() {
        let policy = WebURLPolicy(environment: [:])

        #expect(throws: WebURLPolicyError.restrictedHost("localhost")) {
            try policy.validate("http://localhost:8080")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://127.0.0.1:3000")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::1]:8080")
        }
        #expect(throws: WebURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validate("http://10.0.0.1")
        }
        #expect(throws: WebURLPolicyError.restrictedHost("169.254.169.254")) {
            try policy.validate("http://169.254.169.254/latest/meta-data")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://192.168.1.1/admin")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://172.16.0.5")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://100.64.0.1")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("https://service.local")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://0177.0.0.1")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[fe80::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[fd00::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[ff02::1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::ffff:a00:1]")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validate("http://[::]")
        }
        #expect(throws: WebURLPolicyError.credentialsNotAllowed("https://user:secret@example.com")) {
            try policy.validate("https://user:secret@example.com")
        }
        #expect(throws: WebURLPolicyError.unsupportedScheme("file")) {
            try policy.validate("file:///etc/passwd")
        }
    }

    @Test
    func privateNetworkOverrideIsHostControlled() throws {
        let policy = WebURLPolicy(environment: [
            "ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK": "true"
        ])

        #expect(try policy.validate("http://192.168.1.10:8080").host == "192.168.1.10")
        #expect(try policy.validate("https://service.local").host == "service.local")
    }
}

@Suite
struct WebNetworkRequestPolicyTests {
    let resolver = StaticWebHostResolver(addressesByHost: [
        "public.example": ["93.184.216.34"],
        "mixed.example": ["93.184.216.34", "fd00::1"],
        "rebound.example": ["127.0.0.1"],
        "metadata.example": ["169.254.169.254"],
        "localhost": ["127.0.0.1", "::1"],
        "dualstack.example": ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
    ])

    @Test
    func allowsPublicRequests() throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        try policy.validateRequestURL("https://public.example/app")
        try policy.validateRequestURL("https://dualstack.example/app")
    }

    @Test
    func rejectsNonPublicRequestsFailClosed() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        #expect(throws: WebURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validateRequestURL("http://10.0.0.1/admin")
        }
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://localhost:3000/debug")
        }
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("file:///private/file")
        }
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("ftp://example.com/file")
        }
    }

    @Test
    func rejectsResolvedPrivateAddresses() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        // Mixed A/AAAA where any address is restricted fails closed.
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://mixed.example/app")
        }
        // DNS rebinding: a public-looking host that resolves to loopback.
        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("https://rebound.example/app")
        }
        // DNS rebinding to the cloud metadata endpoint.
        #expect(throws: WebURLPolicyError.self) {
            try policy.validateRequestURL("https://metadata.example/latest/meta-data")
        }
    }

    @Test
    func failsClosedWhenHostIsUnresolvable() {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [:])
        )

        #expect(throws: WebNetworkGuardError.self) {
            try policy.validateRequestURL("https://unresolvable.example/app")
        }
    }

    @Test
    func offloadedValidationMirrorsSynchronousDecisions() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: resolver
        )

        try await policy.validateRequestURLOffloaded("https://public.example/app")
        await #expect(throws: WebNetworkGuardError.self) {
            try await policy.validateRequestURLOffloaded("https://rebound.example/app")
        }
        await #expect(throws: WebURLPolicyError.self) {
            try await policy.validateRequestURLOffloaded("http://127.0.0.1:8080")
        }
    }

    @Test
    func privateNetworkOverrideAppliesToResolvedAddresses() throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [
                "ZENCODE_WEBTOOLS_ALLOW_PRIVATE_NETWORK": "1"
            ]),
            resolver: StaticWebHostResolver(addressesByHost: [
                "192.168.1.10": ["192.168.1.10"],
                "mixed.example": ["93.184.216.34", "fd00::1"],
            ])
        )

        try policy.validateRequestURL("http://192.168.1.10:8080")
        try policy.validateRequestURL("https://mixed.example/app")
    }
}

@Suite
struct WebFetchToolPolicyTests {
    func makeContext(_ environment: [String: String] = [:]) -> FeatureContext {
        FeatureContext(workingDirectory: URL(fileURLWithPath: "/tmp"), environment: environment)
    }

    @Test
    func fetchToolRejectsLoopbackBeforeAnyNetworkActivity() async {
        let tool = WebFetchTool()
        let input = WebFetchTool.Input(url: "http://127.0.0.1:8080/admin", maxBytes: nil, timeoutSeconds: nil)

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(input, context: makeContext())
        }
    }

    @Test
    func fetchToolRejectsMetadataEndpointBeforeAnyNetworkActivity() async {
        let tool = WebFetchTool()
        let input = WebFetchTool.Input(
            url: "http://169.254.169.254/latest/meta-data/iam/security-credentials",
            maxBytes: nil,
            timeoutSeconds: nil
        )

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(input, context: makeContext())
        }
    }

    @Test
    func fetchToolRejectsCredentialsAndNonHTTPScheme() async {
        let tool = WebFetchTool()

        await #expect(throws: WebURLPolicyError.self) {
            _ = try await tool.run(
                WebFetchTool.Input(url: "https://user:secret@example.com", maxBytes: nil, timeoutSeconds: nil),
                context: makeContext()
            )
        }
        await #expect(throws: WebNetworkGuardError.self) {
            _ = try await tool.run(
                WebFetchTool.Input(url: "file:///etc/passwd", maxBytes: nil, timeoutSeconds: nil),
                context: makeContext()
            )
        }
    }

    @Test
    func guardedSessionWiresTheRedirectGuard() {
        let session = WebToolsSupport.makeURLSession(
            policy: WebNetworkRequestPolicy(
                urlPolicy: WebURLPolicy(environment: [:]),
                resolver: StaticWebHostResolver(addressesByHost: [:])
            )
        )
        defer { session.finishTasksAndInvalidate() }

        #expect(session.delegate is WebRedirectGuard)
    }
}

@Suite
struct WebRedirectGuardTests {
    @Test
    func redirectGuardAllowsPublicRedirectAndRejectsPrivateRedirect() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [
                "public.example": ["93.184.216.34"],
                "internal.example": ["10.0.0.1"],
            ])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let allowed = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://public.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://public.example/b")!),
            completionHandler: { allowed.complete(with: $0) }
        )
        let allowedRequest = await allowed.value
        #expect(allowedRequest?.url?.absoluteString == "https://public.example/b")
        task.cancel()

        let blockedTask = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)
        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: blockedTask,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": "https://internal.example/b"]
            )!,
            newRequest: URLRequest(url: URL(string: "https://internal.example/b")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        blockedTask.cancel()
    }

    @Test
    func redirectGuardRejectsRedirectToLoopbackLiteral() async throws {
        let policy = WebNetworkRequestPolicy(
            urlPolicy: WebURLPolicy(environment: [:]),
            resolver: StaticWebHostResolver(addressesByHost: [:])
        )
        let guardDelegate = WebRedirectGuard(policy: policy)
        let task = URLSession.shared.dataTask(with: URL(string: "https://public.example/a")!)

        let blocked = RedirectHookResult()
        guardDelegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: HTTPURLResponse(
                url: URL(string: "https://public.example/a")!,
                statusCode: 301,
                httpVersion: nil,
                headerFields: ["Location": "http://127.0.0.1:9000/secret"]
            )!,
            newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9000/secret")!),
            completionHandler: { blocked.complete(with: $0) }
        )
        let blockedRequest = await blocked.value
        #expect(blockedRequest == nil)
        task.cancel()
    }
}

/// Turns the completion-based redirect hook into a single awaitable value.
private final class RedirectHookResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URLRequest?, Never>?
    private var result: Result<URLRequest?, Never>?

    func complete(with request: URLRequest?) {
        lock.lock()
        if let continuation = self.continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: request)
            return
        }
        result = .success(request)
        lock.unlock()
    }

    var value: URLRequest? {
        get async {
            await withCheckedContinuation { (continuation: CheckedContinuation<URLRequest?, Never>) in
                lock.lock()
                if let result {
                    self.result = nil
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}
