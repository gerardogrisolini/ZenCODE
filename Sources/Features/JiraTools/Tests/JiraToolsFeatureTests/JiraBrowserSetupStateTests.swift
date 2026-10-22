import Foundation
import Synchronization
import Testing

#if os(macOS)
@testable import jira_tools_feature

@Suite
struct JiraBrowserSetupStateTests {
    @Test
    func concurrentPostReceivesConflictWhileTheFirstValidationIsInFlight() async throws {
        let validationStarted = AsyncGate()
        let releaseValidation = AsyncGate()
        let server = try JiraBrowserSetupServer(
            reason: .manual,
            defaults: nil,
            validate: { _ in
                await validationStarted.open()
                await releaseValidation.wait()
                return .failure(JiraSetupValidationError(message: "Invalid credentials"))
            }
        )
        let port = try await server.start()
        defer { server.stop() }

        let firstResponse = Task {
            try await Self.submit(to: port, state: server.formToken)
        }
        await validationStarted.wait()

        let (_, concurrentResponse) = try await Self.submit(to: port, state: server.formToken)
        #expect((concurrentResponse as? HTTPURLResponse)?.statusCode == 409)

        await releaseValidation.open()
        let (_, completedResponse) = try await firstResponse.value
        #expect((completedResponse as? HTTPURLResponse)?.statusCode == 200)
    }

    @Test
    func postWithoutTheOneTimeFormTokenIsRejectedWithoutValidating() async throws {
        let validatorCalls = Mutex(0)
        let server = try JiraBrowserSetupServer(
            reason: .manual,
            defaults: nil,
            validate: { _ in
                validatorCalls.withLock { $0 += 1 }
                return .failure(JiraSetupValidationError(message: "Invalid credentials"))
            }
        )
        let port = try await server.start()
        defer { server.stop() }

        let (missingBody, missingResponse) = try await Self.submit(to: port, state: "")
        #expect((missingResponse as? HTTPURLResponse)?.statusCode == 403)
        #expect(String(decoding: missingBody, as: UTF8.self).contains("did not come from this Jira setup page"))

        let (_, wrongResponse) = try await Self.submit(to: port, state: String(repeating: "0", count: 64))
        #expect((wrongResponse as? HTTPURLResponse)?.statusCode == 403)
        #expect(validatorCalls.withLock { $0 } == 0)

        let (_, validResponse) = try await Self.submit(to: port, state: server.formToken)
        #expect((validResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(validatorCalls.withLock { $0 } == 1)
    }

    @Test
    func crossSiteOriginAndForeignHostAreRejected() async throws {
        let server = try JiraBrowserSetupServer(
            reason: .manual,
            defaults: nil,
            validate: { _ in .failure(JiraSetupValidationError(message: "Invalid credentials")) }
        )
        let port = try await server.start()
        defer { server.stop() }

        var crossSite = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        crossSite.httpMethod = "POST"
        crossSite.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        crossSite.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        crossSite.httpBody = Data("site=x&email=y&token=z&state=\(server.formToken)".utf8)
        let (_, crossSiteResponse) = try await URLSession.shared.data(for: crossSite)
        #expect((crossSiteResponse as? HTTPURLResponse)?.statusCode == 403)

        var rebound = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        rebound.setValue("attacker.example:\(port)", forHTTPHeaderField: "Host")
        let (reboundBody, reboundResponse) = try await URLSession.shared.data(for: rebound)
        #expect((reboundResponse as? HTTPURLResponse)?.statusCode == 403)
        #expect(!String(decoding: reboundBody, as: UTF8.self).contains(server.formToken))

        let (formBody, formResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect((formResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: formBody, as: UTF8.self).contains(server.formToken))
        #expect((formResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control") == "no-store")
    }

    @Test
    func loopbackHeaderChecksAcceptOnlyLocalAuthorities() {
        #expect(JiraBrowserSetupServer.isLoopbackHost(nil))
        #expect(JiraBrowserSetupServer.isLoopbackHost("127.0.0.1:5000"))
        #expect(JiraBrowserSetupServer.isLoopbackHost("localhost"))
        #expect(JiraBrowserSetupServer.isLoopbackHost("[::1]:5000"))
        #expect(!JiraBrowserSetupServer.isLoopbackHost("attacker.example:5000"))
        #expect(!JiraBrowserSetupServer.isLoopbackHost("127.0.0.1.attacker.example"))

        #expect(JiraBrowserSetupServer.isLoopbackOrigin(nil))
        #expect(JiraBrowserSetupServer.isLoopbackOrigin("http://127.0.0.1:5000"))
        #expect(JiraBrowserSetupServer.isLoopbackOrigin("http://localhost:5000"))
        #expect(!JiraBrowserSetupServer.isLoopbackOrigin("null"))
        #expect(!JiraBrowserSetupServer.isLoopbackOrigin("https://evil.example"))
        #expect(!JiraBrowserSetupServer.isLoopbackOrigin("http://evil.example:5000"))

        #expect(JiraBrowserSetupServer.constantTimeEquals("abc", "abc"))
        #expect(!JiraBrowserSetupServer.constantTimeEquals("abc", "abd"))
        #expect(!JiraBrowserSetupServer.constantTimeEquals("", ""))
    }

    @Test
    func admitsOnlyOneValidationUntilTheCurrentSubmissionFinishes() {
        let state = JiraBrowserSetupState()

        #expect(state.beginSubmission())
        #expect(!state.beginSubmission())

        let invalidSubmission = Result<JiraAuthenticatedConfiguration, JiraSetupValidationError>.failure(
            JiraSetupValidationError(message: "Invalid credentials")
        )
        #expect(state.finishSubmission(with: invalidSubmission))
        #expect(state.beginSubmission())
    }

    @Test
    func stopCancelsTheOwnedValidatorAndRejectsItsLateSuccess() async {
        let state = JiraBrowserSetupState()
        #expect(state.beginSubmission())

        let validator = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        state.setSubmissionTask(validator)

        state.stop()

        #expect(validator.isCancelled)
        #expect(!state.finishSubmission(with: .success(Self.configuration)))
        #expect(!state.beginSubmission())
        await validator.value
    }

    private static let configuration: JiraAuthenticatedConfiguration = {
        let stored = try! JiraStoredConfiguration(
            siteURLString: "https://example.atlassian.net",
            email: "person@example.com"
        )
        return JiraAuthenticatedConfiguration(
            configuration: stored,
            apiToken: "token",
            accountName: "Person"
        )
    }()

    private static func submit(to port: UInt16, state: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "site=https%3A%2F%2Fexample.atlassian.net&email=person%40example.com&token=token&state=\(state)".utf8
        )
        return try await URLSession.shared.data(for: request)
    }
}

private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else {
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else {
            return
        }
        isOpen = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}
#endif
