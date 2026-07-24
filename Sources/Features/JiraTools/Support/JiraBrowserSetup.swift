//
//  JiraBrowserSetup.swift
//  ZenCODE
//

import Foundation
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
                await validateAndStore(submission)
            }
        )

        let port = try await server.start()
        let setupURL = URL(string: "http://127.0.0.1:\(port)/")!

        writeLine("Jira setup: complete the connection in your browser.", stderr: true)
        writeLine("If the browser does not open, visit: \(setupURL.absoluteString)", stderr: true)
        openBrowser(setupURL)

        do {
            let result = try await server.waitForResult(timeout: 600)
            server.stop()
            return result
        } catch {
            server.stop()
            throw error
        }
    }

    /// Validates the submitted credentials against Jira and, on success, persists
    /// the configuration and API token. Returns a human-readable error message on
    /// failure so the browser form can be re-rendered with guidance.
    private static func validateAndStore(
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
            let siteURL = try JiraStoredConfiguration.normalizedSiteURL(from: site)
            let configuration = JiraStoredConfiguration(
                siteURLString: siteURL.absoluteString,
                email: email
            )
            let service = JiraRESTService(configuration: configuration, apiToken: token)
            let accountName = try await service.validateCredentials()
            try JiraConfigurationStore.save(configuration)
            try JiraCredentialStore.save(token, account: configuration.credentialAccount)
            return .success(
                JiraAuthenticatedConfiguration(
                    configuration: configuration,
                    apiToken: token,
                    accountName: accountName
                )
            )
        } catch let error as JiraToolsError {
            return .failure(JiraSetupValidationError(message: error.localizedDescription))
        } catch {
            return .failure(JiraSetupValidationError(message: error.localizedDescription))
        }
    }

    private static func openBrowser(_ url: URL) {
        let openURL = URL(fileURLWithPath: "/usr/bin/open")
        guard FileManager.default.isExecutableFile(atPath: openURL.path) else {
            return
        }
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
final class JiraBrowserSetupServer: Sendable {
    typealias Validator = @Sendable (JiraSetupSubmission) async -> Result<JiraAuthenticatedConfiguration, JiraSetupValidationError>

    private let queue = DispatchQueue(label: "JiraTools.JiraBrowserSetupServer")
    private let listener: NWListener
    private let reason: JiraAuthenticationReason
    private let defaults: JiraStoredConfiguration?
    private let validate: Validator
    private let state = JiraBrowserSetupState()

    init(
        reason: JiraAuthenticationReason,
        defaults: JiraStoredConfiguration?,
        validate: @escaping Validator
    ) throws {
        self.reason = reason
        self.defaults = defaults
        self.validate = validate

        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
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
                guard let self else { return }
                state.setReadiness(continuation)
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
        queue.async {
            self.listener.cancel()
        }
    }

    func waitForResult(timeout: TimeInterval) async throws -> JiraAuthenticatedConfiguration {
        try await withThrowingTaskGroup(of: JiraAuthenticatedConfiguration.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        if let buffered = self.state.takeResult(orRegister: continuation) {
                            continuation.resume(with: buffered)
                        }
                    }
                } onCancel: {
                    // Ensure the suspended continuation is released when the task
                    // group cancels this child (e.g. the timeout branch won), so the
                    // group can drain instead of hanging on an unobserved cancel.
                    self.state.resumeResult(with: .failure(CancellationError()))
                }
            }
            group.addTask {
                let nanoseconds = UInt64(max(timeout, 1) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw JiraToolsError.browserSetupTimedOut
            }

            guard let result = try await group.next() else {
                throw JiraToolsError.browserSetupTimedOut
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Listener

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
            guard let self else {
                return
            }
            var buffer = accumulated
            if let data {
                buffer.append(data)
            }
            if error != nil {
                connection.cancel()
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
            let validate = self.validate
            Task {
                let result = await validate(submission)
                switch result {
                case let .success(configuration):
                    self.sendHTML(
                        JiraSetupPage.success(accountName: configuration.accountName),
                        statusCode: 200,
                        on: connection
                    )
                    self.state.resumeResult(with: .success(configuration))
                case let .failure(error):
                    self.sendHTML(
                        self.formPage(error: error.localizedDescription, values: submission),
                        statusCode: 200,
                        on: connection
                    )
                }
            }
        default:
            sendHTML(formPage(error: nil), statusCode: 405, on: connection)
        }
    }

    private func formPage(error: String?, values: JiraSetupSubmission? = nil) -> String {
        JiraSetupPage.form(
            reason: reason,
            error: error,
            site: values?.site ?? defaults?.siteURLString ?? "",
            email: values?.email ?? defaults?.email ?? ""
        )
    }

    private func sendHTML(_ html: String, statusCode: Int, on connection: NWConnection) {
        let body = Data(html.utf8)
        let header = [
            "HTTP/1.1 \(statusCode) \(JiraBrowserSetupServer.reasonPhrase(for: statusCode))",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
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
}

/// Thread-safe continuation storage for the setup server, shared across the
/// listener queue and the awaiting task.
private final class JiraBrowserSetupState: @unchecked Sendable {
    private let lock = NSLock()
    private var readinessContinuation: CheckedContinuation<Void, Error>?
    private var resultContinuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>?
    private var pendingResult: Result<JiraAuthenticatedConfiguration, Error>?
    private var didResumeReadiness = false
    private var didResumeResult = false

    func setReadiness(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        readinessContinuation = continuation
        lock.unlock()
    }

    func resumeReadiness(with result: Result<Void, Error>) {
        lock.lock()
        guard !didResumeReadiness, let continuation = readinessContinuation else {
            lock.unlock()
            return
        }
        didResumeReadiness = true
        readinessContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    /// Registers the result continuation, or returns a buffered result if the
    /// server resolved before the waiter attached.
    func takeResult(
        orRegister continuation: CheckedContinuation<JiraAuthenticatedConfiguration, Error>
    ) -> Result<JiraAuthenticatedConfiguration, Error>? {
        lock.lock()
        if let pending = pendingResult {
            pendingResult = nil
            didResumeResult = true
            lock.unlock()
            return pending
        }
        resultContinuation = continuation
        lock.unlock()
        return nil
    }

    func resumeResult(with result: Result<JiraAuthenticatedConfiguration, Error>) {
        lock.lock()
        guard !didResumeResult else {
            lock.unlock()
            return
        }
        guard let continuation = resultContinuation else {
            if pendingResult == nil {
                pendingResult = result
            }
            lock.unlock()
            return
        }
        didResumeResult = true
        resultContinuation = nil
        lock.unlock()
        continuation.resume(with: result)
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
        guard let headerRange = data.range(of: separator) else {
            return nil
        }
        let headerData = data.subdata(in: data.startIndex ..< headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                continue
            }
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

        return JiraHTTPRequest(
            method: method,
            path: path,
            headers: headers,
            body: body,
            isComplete: isComplete
        )
    }

    static func parseFormURLEncoded(_ data: Data) -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            return [:]
        }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let components = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let rawKey = components.first else {
                continue
            }
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
