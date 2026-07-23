//
//  ZenLogger.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization

public enum ZenLogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: ZenLogLevel, rhs: ZenLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        }
    }

    /// Parses a level name from the `ZENCODE_LOG`/`ZENCODE_LOG_LEVEL` value.
    public static func parse(_ rawValue: String) -> ZenLogLevel? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "debug", "trace", "verbose":
            return .debug
        case "info":
            return .info
        case "warn", "warning":
            return .warning
        case "error", "err":
            return .error
        default:
            return nil
        }
    }
}

public enum ZenLogCategory: String, Sendable {
    case assistantBackend = "AssistantBackendService"
    case applicationDelegate = "ZenCODEApplicationDelegate"
    case cloudChatWorker = "CloudChatWorker"
    case cloudKit = "ZenCODECloudKit"
    case contentViewModel = "ContentViewModel"
    case installedModelCatalog = "InstalledModelCatalogService"
    case memory = "MemoryService"
    case viewActions = "ViewActions"
    case remoteModelCatalogClient = "RemoteModelCatalogClient"
    case remoteNotification = "ZenCODERemoteNotification"
    case remotePrompt = "RemotePrompt"
    case sessionService = "SessionService"
    case bashToolExecutor = "BashToolExecutor"
    case mcpClient = "MCPClient"
    case taskListSync = "TaskListSync"
    case taskExecutionCoordinator = "TaskExecutionCoordinator"
    case taskExecutionEngine = "TaskExecutionEngineSupport"
    case taskLifecycle = "TaskLifecycleService"
    case toolBackendResolver = "ToolBackendResolver"
    case toolDescriptor = "ToolDescriptor"
    case turnFileChangeTracker = "TurnFileChangeTracker"
    case turnGeneration = "TurnGenerationService"
    case userInput = "UserInputService"
    case viewModel = "ViewModel"
    case viewModelRuntime = "ViewModelRuntimeService"
    case xcodeToolExecutor = "XcodeToolExecutor"
    case conversationHistory = "ConversationHistorySupport"
    case diagnostics = "Diagnostics"
}

/// Opt-in local diagnostic logger.
///
/// Logging is disabled by default so no diagnostic output is produced and the
/// ACP/chat stdout stream stays clean. It is enabled explicitly with the
/// `ZENCODE_LOG` environment variable (or programmatically via
/// ``configure(_:)``). Output is always redacted with ``ZenSecretRedactor`` and
/// is written to a local file — or, only when explicitly requested, to stderr —
/// but never to stdout. There is no remote telemetry.
public enum ZenLogger {
    public static func debug(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.debug, category, message)
    }

    public static func info(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.info, category, message)
    }

    public static func warning(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.warning, category, message)
    }

    public static func error(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.error, category, message)
    }

    public static func log(
        _ level: ZenLogLevel,
        _ category: ZenLogCategory,
        _ message: () -> String
    ) {
        guard let sink = ZenLogSink.shared.resolvedSink(minimumLevel: level) else {
            // Disabled or below the active threshold: never evaluate the message
            // closure, so logging stays truly zero-cost when off.
            return
        }
        let rendered = formattedMessage(
            level: level,
            category: category,
            message: message()
        )
        sink.write(timestampedLine: rendered)
    }

    public static func formattedMessage(
        level: ZenLogLevel,
        category: ZenLogCategory,
        message: String
    ) -> String {
        let body = ZenSecretRedactor.redact(
            messageBody(category: category, message: message)
        )
        return "[\(category.rawValue)][\(level.label)] \(body)"
    }

    /// Whether the diagnostic logger is currently emitting output.
    public static var isEnabled: Bool {
        ZenLogSink.shared.isEnabled
    }

    /// A human-readable, secret-free description of where diagnostics are
    /// written, or `nil` when logging is disabled. Used by `zen --doctor`.
    public static var destinationDescription: String? {
        ZenLogSink.shared.destinationDescription
    }

    /// The active minimum level, or `nil` when logging is disabled.
    public static var activeLevel: ZenLogLevel? {
        ZenLogSink.shared.activeLevel
    }

    /// Resolves the current diagnostic destination without opening a file or
    /// writing anything. This is intentionally separate from ``isEnabled`` so
    /// inspection commands such as `zen --doctor` remain read-only.
    public static func previewConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ZenLoggerConfiguration? {
        ZenLoggerConfiguration.resolve(
            environment: environment,
            defaultLogDirectory: AppStorageDirectory.appSupportDirectoryURL()
                .appendingPathComponent("logs", isDirectory: true)
                .standardizedFileURL
        )
    }

    /// Overrides the resolved configuration. Passing `nil` restores resolution
    /// from the process environment. Primarily for tests and explicit hosts.
    public static func configure(_ configuration: ZenLoggerConfiguration?) {
        ZenLogSink.shared.configure(configuration)
    }

    private static func messageBody(
        category: ZenLogCategory,
        message: String
    ) -> String {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryPrefix = "[\(category.rawValue)]"
        if normalizedMessage.hasPrefix(categoryPrefix) {
            return normalizedMessage
                .dropFirst(categoryPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalizedMessage
    }
}

/// Immutable resolved logger configuration.
public struct ZenLoggerConfiguration: Sendable, Equatable {
    public enum Destination: Sendable, Equatable {
        case file(URL)
        case standardError
    }

    public let minimumLevel: ZenLogLevel
    public let destination: Destination

    public init(minimumLevel: ZenLogLevel, destination: Destination) {
        self.minimumLevel = minimumLevel
        self.destination = destination
    }

    /// A secret-free description of the destination for diagnostics/help.
    public var destinationDescription: String {
        switch destination {
        case let .file(url):
            return url.path
        case .standardError:
            return "stderr"
        }
    }

    /// Resolves configuration from an environment, or returns `nil` when logging
    /// is not enabled. Enabling is explicit and opt-in:
    ///
    /// - `ZENCODE_LOG` must be present and truthy. Recognized level names
    ///   (`debug`/`info`/`warning`/`error`) also set the threshold; the special
    ///   value `stderr` selects the stderr destination. `0`/`false`/`off`/`no`
    ///   keep logging disabled.
    /// - `ZENCODE_LOG_LEVEL` overrides the threshold.
    /// - `ZENCODE_LOG_FILE` overrides the destination with an explicit path.
    ///
    /// When enabled without an explicit destination, logs go to a per-run file
    /// under the support directory's `logs/` folder. Output never goes to
    /// stdout.
    public static func resolve(
        environment: [String: String],
        defaultLogDirectory: @autoclosure () -> URL
    ) -> ZenLoggerConfiguration? {
        guard let rawEnable = environment["ZENCODE_LOG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawEnable.isEmpty else {
            return nil
        }
        let normalizedEnable = rawEnable.lowercased()
        if ["0", "false", "off", "no", "disable", "disabled"].contains(normalizedEnable) {
            return nil
        }

        var minimumLevel = ZenLogLevel.parse(rawEnable) ?? .info
        if let rawLevel = environment["ZENCODE_LOG_LEVEL"]?.nilIfBlank,
           let parsedLevel = ZenLogLevel.parse(rawLevel) {
            minimumLevel = parsedLevel
        }

        let destination: Destination
        if let rawFile = environment["ZENCODE_LOG_FILE"]?.nilIfBlank {
            destination = .file(
                URL(fileURLWithPath: (rawFile as NSString).expandingTildeInPath)
                    .standardizedFileURL
            )
        } else if normalizedEnable == "stderr" || normalizedEnable == "2" {
            destination = .standardError
        } else {
            destination = .file(
                defaultLogDirectory()
                    .appendingPathComponent("zencode.log")
                    .standardizedFileURL
            )
        }

        return ZenLoggerConfiguration(
            minimumLevel: minimumLevel,
            destination: destination
        )
    }
}

/// Process-wide diagnostic sink. Thread-safe, lazily resolved, and never writes
/// to stdout.
final class ZenLogSink: Sendable {
    static let shared = ZenLogSink()

    private enum Resolution {
        case unresolved
        case disabled
        case enabled(ActiveSink)
    }

    fileprivate struct ActiveSink {
        let configuration: ZenLoggerConfiguration
        let handle: FileHandle?
    }

    private let state: Mutex<Resolution>
    private let overrideConfiguration: Mutex<ZenLoggerConfiguration??>

    private init() {
        state = Mutex(.unresolved)
        overrideConfiguration = Mutex(.none)
    }

    func configure(_ configuration: ZenLoggerConfiguration?) {
        overrideConfiguration.withLock { $0 = .some(configuration) }
        state.withLock { resolution in
            if case let .enabled(active) = resolution {
                closeIfNeeded(active)
            }
            resolution = .unresolved
        }
    }

    var isEnabled: Bool {
        resolvedActiveSink() != nil
    }

    var destinationDescription: String? {
        resolvedActiveSink()?.configuration.destinationDescription
    }

    var activeLevel: ZenLogLevel? {
        resolvedActiveSink()?.configuration.minimumLevel
    }

    /// Returns a writable sink when logging is enabled and `minimumLevel` meets
    /// the active threshold, otherwise `nil`.
    func resolvedSink(minimumLevel: ZenLogLevel) -> WritableSink? {
        guard let active = resolvedActiveSink(),
              minimumLevel >= active.configuration.minimumLevel else {
            return nil
        }
        return WritableSink(sink: self, active: active)
    }

    fileprivate func write(active: ActiveSink, timestampedLine line: String) {
        let entry = Self.timestampPrefix() + line + "\n"
        guard let data = entry.data(using: .utf8) else {
            return
        }
        state.withLock { _ in
            switch active.configuration.destination {
            case .standardError:
                // Written under the shared state lock so concurrent log lines do
                // not interleave. AgentOutput.standardError is the preserved
                // stderr descriptor, so diagnostics survive stderr silencing and
                // never reach stdout.
                try? AgentOutput.standardError.write(contentsOf: data)
            case .file:
                try? active.handle?.write(contentsOf: data)
            }
        }
    }

    private func resolvedActiveSink() -> ActiveSink? {
        state.withLock { resolution in
            switch resolution {
            case let .enabled(active):
                return active
            case .disabled:
                return nil
            case .unresolved:
                let active = makeActiveSink()
                resolution = active.map(Resolution.enabled) ?? .disabled
                return active
            }
        }
    }

    private func makeActiveSink() -> ActiveSink? {
        let configuration: ZenLoggerConfiguration?
        if let override = overrideConfiguration.withLock({ $0 }) {
            configuration = override
        } else {
            configuration = ZenLoggerConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment,
                defaultLogDirectory: Self.defaultLogDirectory()
            )
        }
        guard let configuration else {
            return nil
        }

        switch configuration.destination {
        case .standardError:
            return ActiveSink(configuration: configuration, handle: nil)
        case let .file(url):
            guard let handle = Self.openLogFile(at: url) else {
                // Never fall back to stdout. If the file cannot be opened,
                // diagnostics stay silent.
                return nil
            }
            return ActiveSink(configuration: configuration, handle: handle)
        }
    }

    private func closeIfNeeded(_ active: ActiveSink) {
        guard case .file = active.configuration.destination else {
            return
        }
        try? active.handle?.close()
    }

    private static func defaultLogDirectory() -> URL {
        AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent("logs", isDirectory: true)
            .standardizedFileURL
    }

    private static func openLogFile(at url: URL) -> FileHandle? {
        let directoryURL = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        _ = try? handle.seekToEnd()
        return handle
    }

    private static func timestampPrefix() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "[\(formatter.string(from: Date()))] "
    }
}

/// A short-lived writable handle returned by ``ZenLogSink/resolvedSink(minimumLevel:)``.
struct WritableSink {
    fileprivate let sink: ZenLogSink
    fileprivate let active: ZenLogSink.ActiveSink

    func write(timestampedLine line: String) {
        sink.write(active: active, timestampedLine: line)
    }
}
