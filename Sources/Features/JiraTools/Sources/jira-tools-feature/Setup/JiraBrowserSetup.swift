import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ToolCore

/// Values submitted by the user through the local browser setup form.
struct JiraSetupSubmission: Sendable {
    let site: String
    let email: String
    let token: String
}

/// Result of a successful browser-based Jira setup: the stored configuration,
/// the validated API token, and the resolved account display name.
struct JiraAuthenticatedConfiguration: Sendable {
    let configuration: JiraStoredConfiguration
    let apiToken: String
    let accountName: String
}

struct JiraSetupValidationError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

#if os(macOS)
import Network

/// Drives the browser-based Jira setup flow entirely inside `jira-tools-feature`.
///
/// It starts a loopback HTTP server, opens the user's browser on a small form
/// where the Jira site URL, Atlassian email and API token are entered, validates
/// the credentials against the Jira REST API, and persists the configuration and
/// token so the next Jira tool call can connect. No terminal (`/dev/tty`) prompt
/// is used, which is what makes it work while running as a tool subprocess.
enum JiraBrowserSetup {
    static func authenticate(
        reason: JiraAuthenticationReason,
        defaults: JiraStoredConfiguration?
    ) async throws -> JiraAuthenticatedConfiguration {
        let server = try JiraBrowserSetupServer(
            reason: reason,
            defaults: defaults,
            validate: { submission in
                await validate(submission)
            }
        )

        let port: UInt16
        do {
            port = try await server.start()
        } catch {
            server.stop()
            throw error
        }
        let setupURL = URL(string: "http://127.0.0.1:\(port)/")!

        writeLine("Jira setup: complete the connection in your browser.", stderr: true)
        writeLine("If the browser does not open, visit: \(setupURL.absoluteString)", stderr: true)
        openBrowser(setupURL)

        let result: JiraAuthenticatedConfiguration
        do {
            result = try await server.waitForResult(timeout: 600)
        } catch {
            server.stop()
            throw error
        }

        // `waitForResult` returns only the submission that the server state
        // accepted. Stop first to cancel/reject every other in-flight path,
        // then make the accepted configuration durable exactly once.
        server.stop()
        try persist(result)
        return result
    }

    /// Validates submitted credentials against Jira without changing local state.
    /// Persistence is deliberately delayed until the server has selected this
    /// result as the single winner of the setup flow.
    private static func validate(
        _ submission: JiraSetupSubmission
    ) async -> Result<JiraAuthenticatedConfiguration, JiraSetupValidationError> {
        guard let site = submission.site.nilIfBlank else {
            return .failure(JiraSetupValidationError(message: "Enter the Jira site URL."))
        }
        guard let email = submission.email.nilIfBlank else {
            return .failure(JiraSetupValidationError(message: "Enter your Atlassian email."))
        }
        guard let token = submission.token.nilIfBlank else {
            return .failure(JiraSetupValidationError(message: "Enter your Atlassian API token."))
        }

        do {
            let configuration = try JiraStoredConfiguration(siteURLString: site, email: email)
            let service = JiraRESTService(configuration: configuration, apiToken: token)
            let accountName = try await service.validateCredentials()
            return .success(
                JiraAuthenticatedConfiguration(configuration: configuration, apiToken: token, accountName: accountName)
            )
        } catch let error as JiraToolsError {
            return .failure(JiraSetupValidationError(message: error.localizedDescription))
        } catch {
            return .failure(JiraSetupValidationError(message: error.localizedDescription))
        }
    }

    private static func persist(_ authenticatedConfiguration: JiraAuthenticatedConfiguration) throws {
        try JiraConfigurationStore.save(authenticatedConfiguration.configuration)
        try JiraCredentialStore.save(
            authenticatedConfiguration.apiToken,
            account: authenticatedConfiguration.configuration.credentialAccount
        )
    }

    private static func openBrowser(_ url: URL) {
        let openURL = URL(fileURLWithPath: "/usr/bin/open")
        guard FileManager.default.isExecutableFile(atPath: openURL.path) else { return }
        let process = Process()
        process.executableURL = openURL
        process.arguments = [url.absoluteString]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

/// Loopback HTTP server that renders the Jira setup form, receives the submitted
/// credentials, and resolves once the supplied validator accepts them.
///
/// The server only ever binds `127.0.0.1`. Every POST must carry the one-time
/// form token embedded in the page served by this process and must come from a
/// loopback origin, so a cross-site form submission from another website open
/// in the same browser (or a DNS-rebinding page) cannot plant foreign Jira
/// credentials.
final class JiraBrowserSetupServer: Sendable {
    typealias Validator = @Sendable (JiraSetupSubmission) async -> Result<JiraAuthenticatedConfiguration, JiraSetupValidationError>

    /// Upper bound for a single HTTP request; the form is a few hundred bytes.
    static let maximumRequestSize = 256 * 1024
    /// How long the listener may take to report `.ready` before setup fails.
    static let startTimeout: TimeInterval = 5

    private let queue = DispatchQueue(label: "JiraTools.JiraBrowserSetupServer")
    private let listener: NWListener
    private let reason: JiraAuthenticationReason
    private let defaults: JiraStoredConfiguration?
    private let validate: Validator
    private let state = JiraBrowserSetupState()
    /// One-time token embedded as a hidden form field and required on POST.
    let formToken: String

    init(reason: JiraAuthenticationReason, defaults: JiraStoredConfiguration?, validate: @escaping Validator) throws {
        self.reason = reason
        self.defaults = defaults
        self.validate = validate
        self.formToken = Self.makeFormToken()

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        // Defense in depth: refuse any non-local peer even if the binding is
        // ever widened.
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = true
        do {
            self.listener = try NWListener(using: parameters)
        } catch {
            throw JiraToolsError.browserSetupFailed(
                "Unable to start the local Jira setup server. \(error.localizedDescription)"
            )
        }
    }

    /// Starts the listener and returns the bound loopback port once ready.
    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: JiraToolsError.browserSetupFailed("The Jira setup server was stopped."))
                    return
                }
                // A listener stuck in `.waiting` never reports `.ready` or
                // `.failed`; bound the wait so setup fails with an actionable
                // error instead of hanging the tool call.
                let state = self.state
                let timeout = Task(name: "JiraBrowserSetup.start-timeout") {
                    try? await Task.sleep(nanoseconds: UInt64(Self.startTimeout * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    state.resumeReadiness(
                        with: .failure(
                            JiraToolsError.browserSetupFailed("The local Jira setup server did not become ready in time.")
                        )
                    )
                }
                state.setReadiness(continuation, timeout: timeout)
                listener.stateUpdateHandler = { [weak self] state in
                    self?.handleListenerState(state)
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection: connection)
                }
                listener.start(queue: queue)
            }
        }

        guard let port = listener.port?.rawValue else {
            throw JiraToolsError.browserSetupFailed("The local Jira setup server did not report a port.")
        }
        return port
    }

    func stop() {
        state.stop()
        queue.async {
            self.listener.cancel()
        }
    }

    func waitForResult(timeout: TimeInterval) async throws -> JiraAuthenticatedConfiguration {
        try await withThrowingTaskGroup(of: JiraAuthenticatedConfiguration.self) { group in
            group.addTask(name: "JiraBrowserSetup.waitForResult") {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if let buffered = self.state.takeResult(orRegister: continuation) {
                            continuation.resume(with: buffered)
                        }
                    }
                } onCancel: {
                    // A cancelled waiter means the setup flow can no longer
                    // consume a winner. Stop synchronously so a validator which
                    // completes after cancellation is rejected and cancelled.
                    self.stop()
                }
            }
            group.addTask(name: "JiraBrowserSetup.waitForResult-timeout") {
                let nanoseconds = UInt64(max(timeout, 1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                // Close the admission gate before reporting timeout. This makes
                // a concurrent validation result late rather than letting it
                // become a buffered winner while the task group unwinds.
                self.stop()
                throw JiraToolsError.browserSetupTimedOut
            }

            guard let result = try await group.next() else { throw JiraToolsError.browserSetupTimedOut }
            group.cancelAll()
            return result
        }
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            self.state.resumeReadiness(with: .success(()))
        case let .failed(error):
            let wrapped = JiraToolsError.browserSetupFailed(
                "The local Jira setup server failed. \(error.localizedDescription)"
            )
            self.state.resumeReadiness(with: .failure(wrapped))
            self.state.resumeResult(with: .failure(wrapped))
        case .cancelled:
            self.state.resumeReadiness(
                with: .failure(JiraToolsError.browserSetupFailed("The Jira setup server was stopped."))
            )
            self.state.resumeResult(
                with: .failure(JiraToolsError.browserSetupFailed("The Jira setup server was stopped."))
            )
        default:
            break
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if error != nil {
                connection.cancel()
                return
            }
            if buffer.count > Self.maximumRequestSize {
                self.sendHTML(JiraSetupPage.notFound, statusCode: 413, on: connection)
                return
            }
            if let request = JiraHTTPRequest.parse(buffer), request.isComplete {
                self.route(request, on: connection)
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func route(_ request: JiraHTTPRequest, on connection: NWConnection) {
        guard request.path == "/" else {
            sendHTML(JiraSetupPage.notFound, statusCode: 404, on: connection)
            return
        }
        // A browser only sends a non-loopback Host for a DNS-rebinding page
        // whose name resolves to 127.0.0.1; such a page must not be able to
        // read the form token or submit the form.
        guard Self.isLoopbackHost(request.headers["host"]) else {
            sendHTML(JiraSetupPage.notFound, statusCode: 403, on: connection)
            return
        }

        switch request.method {
        case "GET":
            sendHTML(formPage(error: nil), statusCode: 200, on: connection)
        case "POST":
            let fields = JiraHTTPRequest.parseFormURLEncoded(request.body)
            let submission = JiraSetupSubmission(
                site: fields["site"] ?? "",
                email: fields["email"] ?? "",
                token: fields["token"] ?? ""
            )

            guard Self.isLoopbackOrigin(request.headers["origin"]),
                  Self.constantTimeEquals(fields["state"] ?? "", formToken) else {
                sendHTML(
                    formPage(
                        error: "The submission did not come from this Jira setup page. Reload the page and try again.",
                        values: submission
                    ),
                    statusCode: 403,
                    on: connection
                )
                return
            }

            guard state.beginSubmission() else {
                sendHTML(
                    formPage(
                        error: "A Jira setup submission is already being validated. Please wait.",
                        values: submission
                    ),
                    statusCode: 409,
                    on: connection
                )
                return
            }

            let validate = self.validate
            let validationTask = Task(name: "JiraBrowserSetup.validate-submission") { [weak self] in
                guard let self else { return }
                let result = await validate(submission)
                guard self.state.finishSubmission(with: result) else { return }
                switch result {
                case let .success(configuration):
                    self.sendHTML(
                        JiraSetupPage.success(accountName: configuration.accountName),
                        statusCode: 200,
                        on: connection
                    )
                case let .failure(error):
                    self.sendHTML(
                        self.formPage(error: error.localizedDescription, values: submission),
                        statusCode: 200,
                        on: connection
                    )
                }
            }
            state.setSubmissionTask(validationTask)
        default:
            sendHTML(formPage(error: nil), statusCode: 405, on: connection)
        }
    }

    private func formPage(error: String?, values: JiraSetupSubmission? = nil) -> String {
        JiraSetupPage.form(
            reason: reason,
            error: error,
            site: values?.site ?? defaults?.siteURLString ?? "",
            email: values?.email ?? defaults?.email ?? "",
            formToken: formToken
        )
    }

    private func sendHTML(_ html: String, statusCode: Int, on connection: NWConnection) {
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(statusCode) \(JiraBrowserSetupServer.reasonPhrase(for: statusCode))",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            // The form page embeds the one-time token; never let it be cached
            // or leak through the Referer of the Atlassian help link.
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data(header.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    private static func makeFormToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    /// Compares two tokens without short-circuiting on the first mismatch.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count, !left.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// Accepts `127.0.0.1`, `localhost` and `[::1]` with or without a port. A
    /// missing header is tolerated (HTTP/1.0 clients); browsers always send it.
    static func isLoopbackHost(_ hostHeader: String?) -> Bool {
        guard let hostHeader = hostHeader?.trimmingCharacters(in: .whitespaces).nilIfBlank else { return true }
        return isLoopbackAuthority(hostHeader)
    }

    /// Accepts a missing `Origin` (same-origin form posts from some clients
    /// omit it) or an explicit loopback `http://` origin. A cross-site form
    /// post always carries the foreign origin and is rejected.
    static func isLoopbackOrigin(_ originHeader: String?) -> Bool {
        guard let origin = originHeader?.trimmingCharacters(in: .whitespaces).nilIfBlank else { return true }
        guard origin.lowercased() != "null",
              let components = URLComponents(string: origin),
              components.scheme?.lowercased() == "http",
              let host = components.host else {
            return false
        }
        return isLoopbackAuthority(host)
    }

    private static func isLoopbackAuthority(_ authority: String) -> Bool {
        let loopbackHosts: Set<String> = ["127.0.0.1", "localhost", "::1"]
        var value = authority.lowercased()
        if loopbackHosts.contains(value) {
            return true
        }
        if value.hasPrefix("[") {
            // Bracketed IPv6 literal, optionally followed by `:port`.
            guard let close = value.firstIndex(of: "]") else { return false }
            value = String(value[value.index(after: value.startIndex)..<close])
        } else if let colon = value.lastIndex(of: ":"), value[colon...].dropFirst().allSatisfy(\.isNumber) {
            value = String(value[..<colon])
        }
        return loopbackHosts.contains(value)
    }
}

/// Thread-safe continuation storage for the setup server, shared across the
/// listener queue and the awaiting task.
final class JiraBrowserSetupState: Sendable {
    private struct State: Sendable {
        var readinessContinuation: CheckedContinuation<Void, Error>?
        var readinessTimeout: Task<Void, Never>?
        var resultContinuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>?
        var pendingResult: Result<JiraAuthenticatedConfiguration, Error>?
        var didResumeReadiness = false
        var didResumeResult = false
        var isStopped = false
        var isValidatingSubmission = false
        var submissionTask: Task<Void, Never>?
    }
    private let state = Mutex(State())

    func setReadiness(_ continuation: CheckedContinuation<Void, Error>, timeout: Task<Void, Never>? = nil) {
        state.withLock { state in
            state.readinessContinuation = continuation
            state.readinessTimeout = timeout
            return
        }
    }

    func resumeReadiness(with result: Result<Void, Error>) {
        let resumption: (CheckedContinuation<Void, Error>, Task<Void, Never>?)? = state.withLock { state in
            guard !state.didResumeReadiness, let continuation = state.readinessContinuation else { return nil }
            state.didResumeReadiness = true
            state.readinessContinuation = nil
            let timeout = state.readinessTimeout
            state.readinessTimeout = nil
            return (continuation, timeout)
        }
        if let (continuation, timeout) = resumption {
            timeout?.cancel()
            continuation.resume(with: result)
        }
    }

    /// Registers the result continuation, or returns a buffered result if the
    /// server resolved before the waiter attached.
    func takeResult(
        orRegister continuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>
    ) -> Result<JiraAuthenticatedConfiguration, Error>? {
        state.withLock { state in
            if let pending = state.pendingResult {
                state.pendingResult = nil
                state.didResumeResult = true
                return pending
            }
            state.resultContinuation = continuation
            return nil
        }
    }

    func resumeResult(with result: Result<JiraAuthenticatedConfiguration, Error>) {
        let continuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>? = state.withLock { state in
            guard !state.didResumeResult else { return nil }
            guard let continuation = state.resultContinuation else {
                state.didResumeResult = true
                if state.pendingResult == nil {
                    state.pendingResult = result
                }
                return nil
            }
            state.didResumeResult = true
            state.resultContinuation = nil
            return continuation
        }
        if let continuation {
            continuation.resume(with: result)
        }
    }

    /// Starts at most one credential validation at a time. The listener queue
    /// may receive simultaneous browser POSTs, while the actual validation runs
    /// asynchronously, so this state must be protected independently of that
    /// queue.
    func beginSubmission() -> Bool {
        state.withLock { state in
            guard !state.isStopped, !state.didResumeResult, !state.isValidatingSubmission else { return false }
            state.isValidatingSubmission = true
            return true
        }
    }

    /// Keeps the asynchronous validator owned by the server. If teardown won
    /// the small race between `beginSubmission` and task creation, cancellation
    /// is requested immediately rather than letting a detached validation outlive
    /// the loopback setup flow.
    func setSubmissionTask(_ task: Task<Void, Never>) {
        let cancelTask = state.withLock { state -> Bool in
            guard !state.isStopped, state.isValidatingSubmission else { return true }
            state.submissionTask = task
            return false
        }
        if cancelTask {
            task.cancel()
        }
    }

    /// Finishes the active submission. Only a successful result can resolve the
    /// setup continuation; failed validation simply permits a new POST. Results
    /// after timeout/stop are ignored, preventing late persistence by callers.
    func finishSubmission(with result: Result<JiraAuthenticatedConfiguration, JiraSetupValidationError>) -> Bool {
        let completion = state.withLock { state -> (CheckedContinuation<JiraAuthenticatedConfiguration, Error>?, Bool) in
            state.isValidatingSubmission = false
            state.submissionTask = nil
            guard !state.isStopped, !state.didResumeResult else { return (nil, false) }
            switch result {
            case let .success(configuration):
                let accepted: Result<JiraAuthenticatedConfiguration, Error> = .success(configuration)
                state.didResumeResult = true
                if let continuation = state.resultContinuation {
                    state.resultContinuation = nil
                    return (continuation, true)
                }
                state.pendingResult = accepted
                return (nil, true)
            case .failure:
                return (nil, true)
            }
        }

        if case let .success(configuration) = result {
            completion.0?.resume(returning: configuration)
        }
        return completion.1
    }

    func stop() {
        let task = state.withLock { state -> Task<Void, Never>? in
            state.isStopped = true
            state.isValidatingSubmission = false
            let task = state.submissionTask
            state.submissionTask = nil
            return task
        }
        task?.cancel()
        resumeResult(with: .failure(CancellationError()))
    }
}

/// Minimal HTTP request representation covering only what the setup form needs.
private struct JiraHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
    let isComplete: Bool

    static func parse(_ data: Data) -> JiraHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex ..< colon]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let body = data.subdata(in: headerRange.upperBound ..< data.endIndex)
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let isComplete = method == "POST" ? body.count >= contentLength : true

        return JiraHTTPRequest(method: method, path: path, headers: headers, body: body, isComplete: isComplete)
    }

    static func parseFormURLEncoded(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = components.first else { continue }
            let key = formDecode(String(rawKey))
            let value = components.count > 1 ? formDecode(String(components[1])) : ""
            result[key] = value
        }
        return result
    }

    private static func formDecode(_ value: String) -> String {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            ?? value.replacingOccurrences(of: "+", with: " ")
    }
}
#endif
