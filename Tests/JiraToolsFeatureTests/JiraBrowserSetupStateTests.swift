import Foundation
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
            try await Self.submit(to: port)
        }
        await validationStarted.wait()

        let (_, concurrentResponse) = try await Self.submit(to: port)
        #expect((concurrentResponse as? HTTPURLResponse)?.statusCode == 409)

        await releaseValidation.open()
        let (_, completedResponse) = try await firstResponse.value
        #expect((completedResponse as? HTTPURLResponse)?.statusCode == 200)
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

    private static func submit(to port: UInt16) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            "site=https%3A%2F%2Fexample.atlassian.net&email=person%40example.com&token=token".utf8
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
