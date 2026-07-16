//
//  ChromeBrowser.swift
//  BrowserTools
//
//  Chrome/Chromium process lifecycle manager and CDP HTTP API client.
//  Ports the browser discovery and spawning logic from ds4_web.c.
//

import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Errors

enum ChromeBrowserError: LocalizedError {
    case chromeNotFound
    case spawnFailed(String)
    case cdpNotReady(String)
    case httpError(String)
    case invalidTabResponse(String)

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
        }
    }
}

// MARK: - Tab info

/// Minimal tab metadata returned by the CDP HTTP `/json/new` endpoint.
struct CDPTabInfo: Sendable {
    let id: String
    let webSocketDebuggerURL: URL
}

// MARK: - Chrome browser manager

/// Discovers, launches, and manages a Chrome/Chromium instance running with
/// `--remote-debugging-port`. The browser is kept alive across calls so that
/// repeated tool invocations reuse the same session and profile.
final class ChromeBrowserManager: @unchecked Sendable {
    static let defaultPort = 9333
    static let connectTimeout: TimeInterval = 3
    static let cdpReadyPollIterations = 80
    static let cdpReadyPollInterval: UInt64 = 250_000_000 // 250 ms

    private let port: Int
    private let profileDirectory: URL
    private let lock = NSLock()
    private var spawnedProcess: Process?
    private var spawnInFlight = false

    private let urlSession: URLSession

    /// - Parameters:
    ///   - port: CDP remote debugging port (defaults to 9333).
    ///   - profileDirectory: Chrome user-data directory (defaults to
    ///     `~/.zencode/browser`).
    init(port: Int = ChromeBrowserManager.defaultPort, profileDirectory: URL? = nil) {
        self.port = port
        self.profileDirectory = profileDirectory ?? Self.defaultProfileDirectory()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.connectTimeout
        configuration.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: configuration)
    }

    // MARK: - Lifecycle

    /// Ensures a Chrome instance with CDP is running. If CDP is already alive
    /// on the configured port, this is a no-op. Otherwise it spawns Chrome and
    /// waits for CDP to become ready. Uses a single-flight guard so concurrent
    /// callers do not launch multiple Chrome instances.
    func ensureRunning() async throws {
        if await isCDPAlive() { return }

        // Single-flight: prevent concurrent spawn attempts.
        if tryAcquireSpawnFlag() {
            // Another caller is already spawning — wait for CDP.
            for _ in 0..<Self.cdpReadyPollIterations {
                try? await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
                if await isCDPAlive() { return }
            }
            throw ChromeBrowserError.cdpNotReady("Chrome did not expose CDP on port \(port)")
        }

        do {
            reapExitedProcess()
            try await spawnChrome()
        } catch {
            releaseSpawnFlag()
            throw error
        }
        releaseSpawnFlag()
    }

    /// Single-flight: returns `true` if another caller is already spawning,
    /// otherwise acquires the flag and returns `false`.
    private func tryAcquireSpawnFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if spawnInFlight { return true }
        spawnInFlight = true
        return false
    }

    private func releaseSpawnFlag() {
        lock.lock()
        spawnInFlight = false
        lock.unlock()
    }

    /// Reaps a previously spawned Chrome process if it has exited. Must be
    /// non-async so the NSLock calls are allowed under Swift 6 concurrency.
    private func reapExitedProcess() {
        lock.lock()
        defer { lock.unlock() }
        if let process = spawnedProcess, !process.isRunning {
            spawnedProcess = nil
        }
    }

    // MARK: - CDP HTTP API

    /// Checks whether the CDP HTTP endpoint is responding.
    func isCDPAlive() async -> Bool {
        guard let url = cdpHTTPURL(path: "/json/version") else { return false }
        do {
            let (data, _) = try await urlSession.data(from: url)
            let body = String(data: data, encoding: .utf8) ?? ""
            return body.contains("webSocketDebuggerUrl")
        } catch {
            return false
        }
    }

    /// Creates a new background tab and returns its metadata.
    ///
    /// Uses the Chromium HTTP endpoint `PUT /json/new` (without a trailing URL
    /// segment) so the tab starts at `about:blank`. The actual navigation is
    /// performed later via the CDP WebSocket `Page.navigate` command, which
    /// gives us error visibility that the HTTP endpoint does not provide.
    func createTab(url: String = "about:blank") async throws -> CDPTabInfo {
        guard let baseURL = cdpHTTPURL(path: "/json/new") else {
            throw ChromeBrowserError.httpError("Unable to build tab creation URL")
        }

        var request = URLRequest(url: baseURL)
        request.httpMethod = "PUT"

        let (data, response) = try await urlSession.data(for: request)
        try validateHTTP(response)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tabID = json["id"] as? String,
              let wsURLString = json["webSocketDebuggerUrl"] as? String,
              let wsURL = URL(string: wsURLString)
        else {
            throw ChromeBrowserError.invalidTabResponse("Missing id or webSocketDebuggerUrl")
        }

        return CDPTabInfo(id: tabID, webSocketDebuggerURL: wsURL)
    }

    /// Closes a tab by its target id.
    func closeTab(id: String) async {
        let encodedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        guard let url = cdpHTTPURL(path: "/json/close/\(encodedID)") else { return }
        _ = try? await urlSession.data(from: url)
    }

    // MARK: - Private: Chrome discovery

    /// Finds a Chrome/Chromium executable, honouring the `ZENCODE_CHROME`
    /// environment variable first.
    static func discoverExecutable() -> String? {
        if let envPath = ProcessInfo.processInfo.environment["ZENCODE_CHROME"],
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

        // Search PATH.
        let names = ["google-chrome", "google-chrome-stable", "chromium", "chromium-browser"]
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
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

        // No Chrome found in standard locations or PATH.
        return nil
    }

    /// On macOS, returns the `.app` bundle name for launching via `open -na`,
    /// or `nil` if no Chrome/Chromium app is installed.
    private static func macOSAppName() -> String? {
        #if os(macOS)
        if ProcessInfo.processInfo.environment["ZENCODE_CHROME"] != nil { return nil }
        let fm = FileManager.default
        if fm.fileExists(atPath: "/Applications/Google Chrome.app") { return "Google Chrome" }
        if fm.fileExists(atPath: "/Applications/Chromium.app") { return "Chromium" }
        return nil
        #else
        nil
        #endif
    }

    // MARK: - Private: spawning

    private func spawnChrome() async throws {
        try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)

        guard let executable = Self.discoverExecutable() else {
            throw ChromeBrowserError.chromeNotFound
        }

        #if os(macOS)
        if let appName = Self.macOSAppName(), FileManager.default.isExecutableFile(atPath: "/usr/bin/open") {
            try launchViaOpen(appName: appName)
        } else {
            try launchDirect(executable: executable)
        }
        #else
        try launchDirect(executable: executable)
        #endif

        // Wait for CDP to become ready.
        for _ in 0..<Self.cdpReadyPollIterations {
            try Task.checkCancellation()
            if await isCDPAlive() { return }
            try await Task.sleep(nanoseconds: Self.cdpReadyPollInterval)
        }

        throw ChromeBrowserError.cdpNotReady("Chrome did not expose CDP on port \(port)")
    }

    #if os(macOS)
    /// Launches Chrome as a proper macOS application using `open -g -na`.
    private func launchViaOpen(appName: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [
            "-g", "-na", appName, "--args",
            "--remote-debugging-port=\(port)",
            "--remote-allow-origins=*",
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--use-mock-keychain",
            "--password-store=basic",
            "--mute-audio",
            "about:blank",
        ]
        try process.run()
        lock.lock()
        spawnedProcess = process
        lock.unlock()
    }
    #endif

    private func launchDirect(executable: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)

        var arguments = [
            "--remote-debugging-port=\(port)",
            "--remote-allow-origins=*",
            "--user-data-dir=\(profileDirectory.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--disable-sync",
            "--password-store=basic",
            "--mute-audio",
            "about:blank",
        ]

        #if os(macOS)
        arguments.append(contentsOf: ["--use-mock-keychain"])
        #else
        // Running as root on Linux requires --no-sandbox.
        if getuid() == 0 {
            arguments.append("--no-sandbox")
        }
        #endif

        process.arguments = arguments

        // Discard stdout/stderr.
        let devNull = FileHandle(forWritingAtPath: "/dev/null")
        if let devNull {
            process.standardOutput = devNull
            process.standardError = devNull
        }

        do {
            try process.run()
        } catch {
            throw ChromeBrowserError.spawnFailed(error.localizedDescription)
        }

        lock.lock()
        spawnedProcess = process
        lock.unlock()
    }

    // MARK: - Private: HTTP helpers

    private func cdpHTTPURL(path: String) -> URL? {
        URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ChromeBrowserError.httpError("Response was not HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ChromeBrowserError.httpError("HTTP status \(http.statusCode)")
        }
    }

    private static func defaultProfileDirectory() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let support = ProcessInfo.processInfo.environment["ZENCODE_SUPPORT_DIRECTORY"]
        let base = support ?? "\(home)/.zencode"
        return URL(fileURLWithPath: "\(base)/browser")
    }
}
