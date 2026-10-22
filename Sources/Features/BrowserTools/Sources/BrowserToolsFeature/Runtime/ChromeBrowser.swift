//
//  ChromeBrowser.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Chrome/Chromium process lifecycle manager and CDP HTTP API client.
//

import Foundation
import Synchronization

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

enum ChromeBrowserError: LocalizedError, Sendable {
    case chromeNotFound
    case spawnFailed(String)
    case cdpNotReady(String)
    case httpError(String)
    case invalidTabResponse(String)
    case pageNotFound(String)
    case unsafeRootExecution
    case profileInUseByLoginSession
    case loginRequiresVisibleBrowser
    case automatedBrowserDidNotExit

    var errorDescription: String? {
        switch self {
        case .chromeNotFound:
            "No Chrome or Chromium executable found. Set ZENCODE_CHROME to a Chrome path."
        case let .spawnFailed(message):
            "Failed to start Chrome: \(message)"
        case let .cdpNotReady(message):
            message
        case let .httpError(message):
            "CDP HTTP request failed: \(message)"
        case let .invalidTabResponse(message):
            "Chrome returned an unexpected response: \(message)"
        case let .pageNotFound(pageID):
            "Browser page '\(pageID)' no longer exists. Open or list pages and use a current pageId."
        case .unsafeRootExecution:
            "Browser refuses to launch Chrome as root without its sandbox. Run ZenCODE as a non-root user, or set ZENCODE_BROWSER_ALLOW_UNSANDBOXED_ROOT=1 only inside an externally isolated environment."
        case .profileInUseByLoginSession:
            "The Browser profile is open in a manual login window started by browser.login. Ask the user to finish signing in and quit that Chrome window, then retry."
        case .loginRequiresVisibleBrowser:
            "browser.login needs a visible Chrome window, but ZENCODE_BROWSER_HEADLESS is enabled. Unset it on a machine with a display to sign in manually."
        case .automatedBrowserDidNotExit:
            "The automated Browser Chrome instance did not exit, so the manual login window cannot use its profile. Quit Chrome for the Browser profile and retry."
        }
    }
}

// MARK: - Configuration

/// Process-level Browser configuration. It is intentionally resolved from the
/// feature context rather than exposing security switches as model-controlled
/// tool arguments.
struct ChromeBrowserConfiguration: Sendable {
    let portOverride: Int?
    let profileDirectory: URL
    let environment: [String: String]
    let launchesHeadless: Bool
    let allowsUnsandboxedRoot: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profileDirectory: URL? = nil,
        portOverride: Int? = nil
    ) {
        self.environment = environment
        self.portOverride = portOverride ?? Self.positivePort(environment["ZENCODE_BROWSER_CDP_PORT"])
        self.profileDirectory = profileDirectory ?? Self.defaultProfileDirectory(environment: environment)
        self.launchesHeadless = Self.enabled(environment["ZENCODE_BROWSER_HEADLESS"])
        self.allowsUnsandboxedRoot = Self.enabled(environment["ZENCODE_BROWSER_ALLOW_UNSANDBOXED_ROOT"])
    }

    private static func positivePort(_ rawValue: String?) -> Int? {
        guard let rawValue,
              let port = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    private static func enabled(_ rawValue: String?) -> Bool {
        ["1", "true", "yes", "on"].contains(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func defaultProfileDirectory(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let support = environment["ZENCODE_SUPPORT_DIRECTORY"]
        let base = support ?? "\(home)/.zencode"
        return URL(fileURLWithPath: "\(base)/browser", isDirectory: true)
    }
}

// MARK: - Tab info

/// Metadata for a page target exposed by Chrome's `/json/list` and `/json/new` endpoints.
struct CDPTabInfo: Sendable, Equatable {
    let id: String
    let title: String
    let url: String
    let webSocketDebuggerURL: URL
}

private struct CDPVersionInfo: Decodable {
    let webSocketDebuggerURL: String

    enum CodingKeys: String, CodingKey {
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }
}

private struct CDPHTTPPageInfo: Decodable {
    let id: String
    let type: String
    let title: String?
    let url: String?
    let webSocketDebuggerURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case url
        case webSocketDebuggerURL = "webSocketDebuggerUrl"
    }

    func tabInfo(expectedPort: Int) throws -> CDPTabInfo {
        guard let webSocketDebuggerURL,
              let webSocketURL = URL(string: webSocketDebuggerURL),
              ChromeBrowserManager.isTrustedDebuggerURL(webSocketURL, expectedPort: expectedPort)
        else {
            throw ChromeBrowserError.invalidTabResponse("Missing or untrusted webSocketDebuggerUrl")
        }
        return CDPTabInfo(
            id: id,
            title: ChromeBrowserManager.unescapedTargetTitle(title ?? ""),
            url: url ?? "",
            webSocketDebuggerURL: webSocketURL
        )
    }
}

// MARK: - Chrome browser manager

/// Discovers and manages the dedicated Chrome/Chromium instance used by the
/// opt-in Browser feature. Pages are persistent Chrome targets, so successive
/// one-shot feature invocations can reconnect through their target ids.
final class ChromeBrowserManager: Sendable {
    static let connectTimeout: TimeInterval = 3
    static let cdpReadyPollIterations = 80
    static let cdpReadyPollInterval: UInt64 = 250_000_000 // 250 ms

    private struct State: Sendable {
        var spawnedProcess: Process?
        var spawnInFlight = false
        var resolvedPort: Int?
    }

    private let configuration: ChromeBrowserConfiguration
    private let state = Mutex(State())
    private let urlSession: URLSession

    init(configuration: ChromeBrowserConfiguration = .init()) {
        self.configuration = configuration
        let urlConfiguration = URLSessionConfiguration.ephemeral
        urlConfiguration.timeoutIntervalForRequest = Self.connectTimeout
        urlConfiguration.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: urlConfiguration)
    }

    deinit {
        urlSession.invalidateAndCancel()
    }

    // MARK: - Lifecycle

    /// Ensures that a dedicated Chrome instance is reachable on loopback.
    /// Dynamic debugging ports are discovered through Chrome's
    /// `DevToolsActivePort` file in the dedicated profile; a fixed port remains
    /// available only as an explicit environment override for compatibility.
    func ensureRunning() async throws {
        if await discoverLivePort() != nil {
            return
        }

        guard acquireSpawnLease() else {
            for _ in 0..<Self.cdpReadyPollIterations {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
                if await discoverLivePort() != nil {
                    return
                }
            }
            throw ChromeBrowserError.cdpNotReady("Chrome did not expose a trusted CDP endpoint for the Browser profile")
        }
        defer { releaseSpawnLease() }

        if await discoverLivePort() != nil {
            return
        }

        // A Chrome that owns the profile without exposing CDP is normally the
        // manual browser.login window. Launching another instance would only
        // forward the arguments to it and never open a debugging port. Give a
        // concurrently starting automated instance time to publish its port
        // before reporting the profile as busy.
        if Self.profileLockOwnerPID(profileDirectory: configuration.profileDirectory) != nil {
            for _ in 0..<Self.cdpReadyPollIterations {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
                if await discoverLivePort() != nil {
                    return
                }
                if Self.profileLockOwnerPID(profileDirectory: configuration.profileDirectory) == nil {
                    break
                }
            }
            if Self.profileLockOwnerPID(profileDirectory: configuration.profileDirectory) != nil {
                throw ChromeBrowserError.profileInUseByLoginSession
            }
        }

        try await spawnChrome(arguments: Self.automationLaunchArguments(configuration: configuration))
        for _ in 0..<Self.cdpReadyPollIterations {
            try Task.checkCancellation()
            if await discoverLivePort() != nil {
                return
            }
            try await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
        }

        throw ChromeBrowserError.cdpNotReady("Chrome did not expose CDP for the Browser profile within the startup timeout")
    }

    private func acquireSpawnLease() -> Bool {
        state.withLock { state in
            guard !state.spawnInFlight else { return false }
            state.spawnInFlight = true
            return true
        }
    }

    private func releaseSpawnLease() {
        state.withLock { state in
            state.spawnInFlight = false
            return
        }
    }

    private func setResolvedPort(_ port: Int) {
        state.withLock { state in
            state.resolvedPort = port
            return
        }
    }

    private func currentResolvedPort() -> Int? {
        state.withLock { state in
            state.resolvedPort
        }
    }

    private func reapExitedProcess() {
        state.withLock { state in
            if let process = state.spawnedProcess, !process.isRunning {
                state.spawnedProcess = nil
            }
            return
        }
    }

    private func discoverLivePort() async -> Int? {
        var candidates: [Int] = []
        if let port = currentResolvedPort() {
            candidates.append(port)
        }
        if let port = configuration.portOverride, !candidates.contains(port) {
            candidates.append(port)
        }
        if let port = readActivePort(), !candidates.contains(port) {
            candidates.append(port)
        }

        for port in candidates where await endpointIsAlive(on: port) {
            setResolvedPort(port)
            return port
        }
        return nil
    }

    // MARK: - Manual login session

    /// Opens the dedicated Browser profile in an ordinary Chrome window with no
    /// remote debugging and no injected scripts, so the user can sign in to
    /// sites that reject automated browsers. A running automated instance is
    /// closed first because one profile can be used by only one Chrome process.
    /// Returns whether an automated instance was closed.
    @discardableResult
    func launchLoginSession(url: URL?) async throws -> Bool {
        guard !configuration.launchesHeadless else {
            throw ChromeBrowserError.loginRequiresVisibleBrowser
        }

        var closedAutomatedBrowser = false
        if let port = await discoverLivePort() {
            await closeAutomatedBrowser(port: port)
            closedAutomatedBrowser = true
            var exited = false
            for _ in 0..<Self.cdpReadyPollIterations {
                try Task.checkCancellation()
                if Self.profileLockOwnerPID(profileDirectory: configuration.profileDirectory) == nil,
                   await !endpointIsAlive(on: port)
                {
                    exited = true
                    break
                }
                try await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
            }
            guard exited else { throw ChromeBrowserError.automatedBrowserDidNotExit }
            state.withLock { state in
                state.resolvedPort = nil
                return
            }
        }

        try await spawnChrome(
            arguments: Self.loginLaunchArguments(configuration: configuration, url: url),
            inForeground: true
        )
        return closedAutomatedBrowser
    }

    private func closeAutomatedBrowser(port: Int) async {
        guard let url = cdpHTTPURL(port: port, path: "/json/version"),
              let (data, response) = try? await urlSession.data(from: url),
              (try? validateHTTP(response)) != nil,
              let version = try? JSONDecoder().decode(CDPVersionInfo.self, from: data),
              let debuggerURL = URL(string: version.webSocketDebuggerURL),
              Self.isTrustedDebuggerURL(debuggerURL, expectedPort: port)
        else {
            return
        }
        let session = CDPSession(
            webSocketURL: debuggerURL,
            configuration: CDPSessionConfiguration(environment: configuration.environment)
        )
        session.connect()
        defer { session.disconnect() }
        // Chrome may drop the socket before acknowledging Browser.close.
        _ = try? await session.send(method: "Browser.close")
    }

    /// Returns the live process that owns the profile's `SingletonLock`, if
    /// any. Chrome stores the owner as a `hostname-pid` symlink target.
    static func profileLockOwnerPID(profileDirectory: URL) -> Int32? {
        let lockPath = profileDirectory.appendingPathComponent("SingletonLock").path
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath) else {
            return nil
        }
        return profileLockOwnerPID(lockTarget: target) { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
    }

    static func profileLockOwnerPID(lockTarget: String, isAlive: (Int32) -> Bool) -> Int32? {
        guard let separator = lockTarget.lastIndex(of: "-"),
              let pid = Int32(lockTarget[lockTarget.index(after: separator)...]),
              pid > 0,
              isAlive(pid)
        else {
            return nil
        }
        return pid
    }

    // MARK: - CDP HTTP API

    /// Creates a persistent background page target. Its id can be passed to
    /// later Browser tool calls even though each feature invocation is a new
    /// process.
    func createTab() async throws -> CDPTabInfo {
        let port = try await requiredPort()
        guard let baseURL = cdpHTTPURL(port: port, path: "/json/new") else {
            throw ChromeBrowserError.httpError("Unable to build tab creation URL")
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "PUT"
        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)

        do {
            return try JSONDecoder().decode(CDPHTTPPageInfo.self, from: data)
                .tabInfo(expectedPort: port)
        } catch let error as ChromeBrowserError {
            throw error
        } catch {
            throw ChromeBrowserError.invalidTabResponse(error.localizedDescription)
        }
    }

    /// Lists persistent page targets owned by the dedicated Browser profile.
    func listTabs() async throws -> [CDPTabInfo] {
        let port = try await requiredPort()
        guard let url = cdpHTTPURL(port: port, path: "/json/list") else {
            throw ChromeBrowserError.httpError("Unable to build tab list URL")
        }
        let (data, response) = try await urlSession.data(from: url)
        try validateHTTP(response)

        do {
            let pages = try JSONDecoder().decode([CDPHTTPPageInfo].self, from: data)
            return try pages
                .filter { $0.type == "page" }
                .map { try $0.tabInfo(expectedPort: port) }
        } catch let error as ChromeBrowserError {
            throw error
        } catch {
            throw ChromeBrowserError.invalidTabResponse(error.localizedDescription)
        }
    }

    func tab(id: String) async throws -> CDPTabInfo {
        let tabID = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tabID.isEmpty else { throw ChromeBrowserError.pageNotFound(id) }
        let tabs = try await listTabs()
        guard let tab = tabs.first(where: { $0.id == tabID }) else { throw ChromeBrowserError.pageNotFound(tabID) }
        return tab
    }

    /// Closes a page by its target id. Closing a missing page is intentionally
    /// idempotent so cleanup remains safe after browser-side navigation/errors.
    func closeTab(id: String) async {
        guard let port = await discoverLivePort() else { return }
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = cdpHTTPURL(port: port, path: "/json/close/\(encodedID)") else { return }
        _ = try? await urlSession.data(from: url)
    }

    private func requiredPort() async throws -> Int {
        if let port = await discoverLivePort() {
            return port
        }
        try await ensureRunning()
        guard let port = await discoverLivePort() else {
            throw ChromeBrowserError.cdpNotReady("Chrome did not expose a CDP endpoint")
        }
        return port
    }

    private func endpointIsAlive(on port: Int) async -> Bool {
        guard let url = cdpHTTPURL(port: port, path: "/json/version") else { return false }
        do {
            let (data, response) = try await urlSession.data(from: url)
            try validateHTTP(response)
            let version = try JSONDecoder().decode(CDPVersionInfo.self, from: data)
            guard let debuggerURL = URL(string: version.webSocketDebuggerURL) else { return false }
            return Self.isTrustedDebuggerURL(debuggerURL, expectedPort: port)
        } catch {
            return false
        }
    }

    static func isTrustedDebuggerURL(_ url: URL, expectedPort: Int) -> Bool {
        let host = url.host?.lowercased()
        return url.scheme?.lowercased() == "ws"
            && ["127.0.0.1", "localhost", "::1"].contains(host)
            && url.port == expectedPort
            && url.path.hasPrefix("/devtools/")
    }

    /// Chrome's `/json/list` and `/json/new` endpoints HTML-escape target
    /// titles (`base::EscapeForHTML`: `<`, `>`, `&`, `"`, `'`). Undo exactly
    /// that escaping so `browser.pages` reports the same title as
    /// `document.title` does for the other page tools.
    static func unescapedTargetTitle(_ title: String) -> String {
        guard title.contains("&") else { return title }
        return title
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Chrome discovery

    static func discoverExecutable(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if let envPath = environment["ZENCODE_CHROME"],
           !envPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: envPath)
        {
            return envPath
        }

        #if os(macOS)
        let macOSApps = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
        ]
        for path in macOSApps where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        #endif

        let linuxPaths = [
            "/usr/bin/google-chrome",
            "/usr/bin/google-chrome-stable",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
            "/opt/google/chrome/chrome",
        ]
        for path in linuxPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
        if let pathEnv = environment["PATH"] {
            for directory in pathEnv.split(separator: ":") {
                let dir = String(directory)
                for name in names {
                    let candidate = "\(dir)/\(name)"
                    if FileManager.default.isExecutableFile(atPath: candidate) {
                        return candidate
                    }
                }
            }
        }
        return nil
    }

    private static func macOSAppName(environment: [String: String]) -> String? {
        #if os(macOS)
        if environment["ZENCODE_CHROME"] != nil { return nil }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: "/Applications/Google Chrome.app") { return "Google Chrome" }
        if fileManager.fileExists(atPath: "/Applications/Chromium.app") { return "Chromium" }
        return nil
        #else
        nil
        #endif
    }

    // MARK: - Spawning

    private func spawnChrome(arguments: [String], inForeground: Bool = false) async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: configuration.profileDirectory, withIntermediateDirectories: true)
        #if canImport(Darwin) || canImport(Glibc)
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.profileDirectory.path)
        #endif

        #if !os(macOS)
        if getuid() == 0, !configuration.allowsUnsandboxedRoot {
            throw ChromeBrowserError.unsafeRootExecution
        }
        #endif

        guard let executable = Self.discoverExecutable(environment: configuration.environment) else {
            throw ChromeBrowserError.chromeNotFound
        }

        reapExitedProcess()
        #if os(macOS)
        if let appName = Self.macOSAppName(environment: configuration.environment),
           FileManager.default.isExecutableFile(atPath: "/usr/bin/open")
        {
            try launchViaOpen(appName: appName, arguments: arguments, inForeground: inForeground)
        } else {
            try launchDirect(executable: executable, arguments: arguments)
        }
        #else
        try launchDirect(executable: executable, arguments: arguments)
        #endif
    }

    /// Arguments shared by the automated and the manual login instance. Both
    /// must agree on the profile and on credential storage, otherwise cookies
    /// saved during a manual login could not be decrypted by the automated
    /// instance. On macOS Chrome uses the real Keychain like a normal install.
    static func profileLaunchArguments(configuration: ChromeBrowserConfiguration) -> [String] {
        var arguments = [
            "--user-data-dir=\(configuration.profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        #if !os(macOS)
        // Linux machines (including headless ones) may have no keyring daemon;
        // a keyring prompt would block the automated instance.
        arguments.append("--password-store=basic")
        #endif
        return arguments
    }

    static func automationLaunchArguments(configuration: ChromeBrowserConfiguration) -> [String] {
        let port = configuration.portOverride ?? 0
        var arguments = [
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=\(port)",
        ]
        arguments += profileLaunchArguments(configuration: configuration)
        arguments.append("--mute-audio")
        if configuration.launchesHeadless {
            arguments.append("--headless=new")
        }
        arguments.append("about:blank")
        return arguments
    }

    /// A manual login instance deliberately exposes no debugging endpoint.
    static func loginLaunchArguments(configuration: ChromeBrowserConfiguration, url: URL?) -> [String] {
        profileLaunchArguments(configuration: configuration) + [url?.absoluteString ?? "about:blank"]
    }

    #if os(macOS)
    private func launchViaOpen(appName: String, arguments: [String], inForeground: Bool) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = (inForeground ? [] : ["-g"]) + ["-na", appName, "--args"] + arguments
        discardProcessOutput(process)
        try process.run()
        rememberSpawnedProcess(process)
    }
    #endif

    private func launchDirect(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        discardProcessOutput(process)
        do {
            try process.run()
        } catch {
            throw ChromeBrowserError.spawnFailed(error.localizedDescription)
        }
        rememberSpawnedProcess(process)
    }

    private func discardProcessOutput(_ process: Process) {
        // `FileHandle.nullDevice` needs no explicit close in the parent, unlike
        // a handle opened on /dev/null for every spawn.
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    private func rememberSpawnedProcess(_ process: Process) {
        state.withLock { state in
            state.spawnedProcess = process
            return
        }
    }

    // MARK: - Helpers

    private func readActivePort() -> Int? {
        let activePortURL = configuration.profileDirectory.appendingPathComponent("DevToolsActivePort")
        guard let contents = try? String(contentsOf: activePortURL, encoding: .utf8),
              let firstLine = contents.split(whereSeparator: \.isNewline).first,
              let port = Int(firstLine),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    private func cdpHTTPURL(port: Int, path: String) -> URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChromeBrowserError.httpError("Response was not HTTP") }
        guard (200..<300).contains(http.statusCode) else { throw ChromeBrowserError.httpError("HTTP status \(http.statusCode)") }
    }
}
