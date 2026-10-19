//
//  ZenLogger.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization
import ToolCore

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

    /// Parses a level name from the `ZENCODE_LOG` value.
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
    case conversationHistory = "ConversationHistorySupport"
    case diagnostics = "Diagnostics"
}

/// Opt-in local diagnostic logger.
///
/// Logging is disabled by default so no diagnostic output is produced and the
/// ACP/chat stdout stream stays clean. It is enabled explicitly with the
/// `ZENCODE_LOG` environment variable (or programmatically via
/// ``configure(_:)``). Output is always redacted with ``ZenSecretRedactor`` and
/// is emitted through the shared platform system logger (Unified Logging on
/// Apple platforms, syslog/journal through `logger(1)` on Linux/WSL) — never to
/// stdout, stderr, or an application-owned file. There is no remote telemetry.
public enum ZenLogger {
    /// Maximum characters of a redacted diagnostic message body. Longer bodies
    /// are truncated so a single pathological diagnostic cannot flood the
    /// system log.
    public static let maximumMessageCharacters = 4_096

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
        guard let configuration = resolvedConfiguration(),
              level >= configuration.minimumLevel else {
            // Disabled or below the active threshold: never evaluate the message
            // closure, so logging stays truly zero-cost when off.
            return
        }
        SystemLogEmitter.emit(
            systemLogRecord(
                level: level,
                category: category,
                message: message()
            )
        )
    }

    /// Renders the public, redacted, bounded system-log record for a message.
    /// Threshold gating happens in ``log(_:_:_:)``: rendering itself depends
    /// only on level, category, and body.
    static func systemLogRecord(
        level: ZenLogLevel,
        category: ZenLogCategory,
        message: String
    ) -> SystemLogRecord {
        SystemLogRecord(
            category: diagnosticCategory(for: category),
            severity: systemLogSeverity(for: level),
            message: limitedMessage(
                formattedMessage(
                    level: level,
                    category: category,
                    message: message
                )
            )
        )
    }

    /// Maps ``ZenLogLevel`` onto the shared system-log severity scale.
    static func systemLogSeverity(for level: ZenLogLevel) -> SystemLogSeverity {
        switch level {
        case .debug:
            return .debug
        case .info:
            return .info
        case .warning:
            return .warning
        case .error:
            return .error
        }
    }

    static func diagnosticCategory(for category: ZenLogCategory) -> String {
        "diagnostics-\(category.rawValue)"
    }

    static func limitedMessage(_ message: String) -> String {
        guard message.count > maximumMessageCharacters else {
            return message
        }
        return String(message.prefix(maximumMessageCharacters)) + "…"
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
        resolvedConfiguration() != nil
    }

    /// A human-readable, secret-free description of where diagnostics are
    /// written, or `nil` when logging is disabled. Used by `zen --doctor`.
    public static var destinationDescription: String? {
        resolvedConfiguration()?.destinationDescription
    }

    /// The active minimum level, or `nil` when logging is disabled.
    public static var activeLevel: ZenLogLevel? {
        resolvedConfiguration()?.minimumLevel
    }

    /// Resolves the current diagnostic destination without writing anything.
    /// This is intentionally separate from ``isEnabled`` so inspection commands
    /// such as `zen --doctor` remain read-only. Resolution is pure: no support
    /// directory, file, or system-log handle is created here.
    public static func previewConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ZenLoggerConfiguration? {
        ZenLoggerConfiguration.resolve(environment: environment)
    }

    /// Resolves the current diagnostic destination using the historical
    /// directory-taking API.
    ///
    /// `supportDirectory` is accepted for source compatibility but ignored:
    /// diagnostics now resolve exclusively to the system log and never create
    /// an application support directory. The parameter intentionally has no
    /// default value so this overload cannot be ambiguous with
    /// ``previewConfiguration(environment:)``.
    public static func previewConfiguration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        supportDirectory: URL?
    ) -> ZenLoggerConfiguration? {
        ZenLoggerConfiguration.resolve(environment: environment)
    }

    /// Overrides the resolved configuration. Passing `nil` clears any override
    /// and restores resolution from the process environment; use ``disable()``
    /// to force diagnostics off regardless of the environment. Primarily for
    /// tests and explicit hosts.
    public static func configure(_ configuration: ZenLoggerConfiguration?) {
        ZenLogConfigurationStore.shared.configure(
            configuration.map(ZenLogOverride.configuration) ?? .environment
        )
    }

    /// Forces diagnostics off for the current process, ignoring `ZENCODE_LOG`.
    /// Distinct from ``configure(_:)`` with `nil`, which restores environment
    /// resolution instead of disabling.
    public static func disable() {
        ZenLogConfigurationStore.shared.configure(.disabled)
    }

    static func resolvedConfiguration() -> ZenLoggerConfiguration? {
        ZenLogConfigurationStore.shared.resolvedConfiguration()
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
        /// Records are emitted through the shared platform system logger
        /// (Unified Logging on Apple platforms, syslog/journal via `logger(1)`
        /// on Linux/WSL) under subsystem `com.zencode.zen`.
        case systemLog

        /// The legacy file destination was removed together with the
        /// application-owned log file and its timestamp/retention behaviour.
        /// Use ``systemLog``.
        @available(*, unavailable, message: "ZenCODE diagnostics now use the system log; use .systemLog")
        case file(URL)

        /// The legacy stderr destination was removed: diagnostics never write
        /// to stdout or stderr. Use ``systemLog``.
        @available(*, unavailable, message: "ZenCODE diagnostics never write to stderr; use .systemLog")
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
        case .systemLog:
            return "system log"
        }
    }

    /// Values that historically selected a removed application-owned
    /// destination rather than a threshold.
    private static let legacyDestinationValues: Set<String> = ["stderr", "2"]

    /// Whether a normalized `ZENCODE_LOG` value names the removed stderr
    /// destination (`stderr`/`2`) instead of an enabling value or threshold.
    /// Such values must not silently enable the system log.
    static func isLegacyDestinationValue(_ normalizedEnable: String) -> Bool {
        legacyDestinationValues.contains(normalizedEnable)
    }

    /// Resolves configuration from an environment, or returns `nil` when logging
    /// is not enabled. Enabling is explicit and opt-in:
    ///
    /// - `ZENCODE_LOG` must be present, truthy, and not a legacy destination
    ///   value. Recognized level names (`debug`/`info`/`warning`/`error`) also
    ///   set the threshold; `0`/`false`/`off`/`no` keep logging disabled.
    ///   `ZENCODE_LOG=stderr` and `ZENCODE_LOG=2` no longer select a
    ///   destination and do not enable logging.
    /// - `ZENCODE_LOG_FILE` is a removed legacy destination override and is
    ///   ignored entirely.
    ///
    /// When enabled, records are emitted through the shared platform system
    /// logger; no application-owned file is opened and output never goes to
    /// stdout or stderr.
    public static func resolve(
        environment: [String: String]
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
        if isLegacyDestinationValue(normalizedEnable) {
            return nil
        }

        return ZenLoggerConfiguration(
            minimumLevel: ZenLogLevel.parse(rawEnable) ?? .info,
            destination: .systemLog
        )
    }
}

/// Unambiguous override state for the process-wide diagnostic configuration.
///
/// A three-case enum instead of a nested optional: `Optional<Optional<_>>`
/// made "no override" and "explicitly disabled" visually interchangeable and
/// silently turned ``ZenLogger/configure(_:)`` with `nil` into a permanent
/// disable instead of the documented environment restore.
enum ZenLogOverride: Sendable, Equatable {
    /// No override: resolve from the environment.
    case environment
    /// Explicitly enabled with a fixed configuration.
    case configuration(ZenLoggerConfiguration)
    /// Explicitly disabled, whatever the environment says.
    case disabled
}

/// Process-wide resolved diagnostic configuration. Thread-safe and lazily
/// resolved from the process environment unless overridden; resolution itself
/// performs no I/O, so nothing is ever opened, created, or written.
final class ZenLogConfigurationStore: Sendable {
    static let shared = ZenLogConfigurationStore()

    private enum Resolution {
        case unresolved
        case disabled
        case enabled(ZenLoggerConfiguration)
    }

    private let state: Mutex<Resolution>
    private let override: Mutex<ZenLogOverride>
    /// Environment seam: the shared store reads the process environment, while
    /// tests inject a fixed environment to prove restore-versus-disable
    /// behaviour deterministically and without mutating the process.
    private let environmentProvider: @Sendable () -> [String: String]

    init(
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        state = Mutex(.unresolved)
        override = Mutex(.environment)
        self.environmentProvider = environmentProvider
    }

    func configure(_ override: ZenLogOverride) {
        self.override.withLock { $0 = override }
        state.withLock { $0 = .unresolved }
    }

    /// Returns the active configuration when logging is enabled, otherwise
    /// `nil`.
    func resolvedConfiguration() -> ZenLoggerConfiguration? {
        state.withLock { resolution in
            switch resolution {
            case let .enabled(configuration):
                return configuration
            case .disabled:
                return nil
            case .unresolved:
                let configuration = makeConfiguration()
                resolution = configuration.map(Resolution.enabled) ?? .disabled
                return configuration
            }
        }
    }

    private func makeConfiguration() -> ZenLoggerConfiguration? {
        switch override.withLock({ $0 }) {
        case .environment:
            return ZenLoggerConfiguration.resolve(
                environment: environmentProvider()
            )
        case let .configuration(configuration):
            return configuration
        case .disabled:
            return nil
        }
    }
}
