//
//  DS4ServerSupervisor.swift
//  ZenCODE
//
//  Coordinates an optional local ds4 HTTP server. The supervisor may adopt a
//  compatible, explicitly-candidate loopback endpoint, but only owns and stops
//  children it launched itself.
//

import FeatureKit
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Identifies who is allowed to terminate the process behind an endpoint.
///
/// An adopted endpoint is deliberately process-less: ZenCODE may use and
/// detach from it, but it must never infer a killable process from a port or a
/// PID returned by an HTTP probe.
public enum DS4ServerEndpointOwnership: String, Equatable, Sendable {
    /// The endpoint belongs to a child started by this supervisor.
    case managed
    /// The endpoint was already listening before this supervisor started.
    case adopted
}

/// The endpoint returned after a ds4 child has answered its model catalogue
/// request. `baseURL` is the OpenAI-compatible `/v1` root.
public struct DS4ServerEndpoint: Equatable, Sendable {
    public let baseURL: URL
    public let modelsURL: URL
    public let host: String
    public let port: Int
    public let modelID: String
    public let processIdentifier: Int32?
    public let ownership: DS4ServerEndpointOwnership

    public init(
        baseURL: URL,
        modelsURL: URL,
        host: String,
        port: Int,
        modelID: String,
        processIdentifier: Int32? = nil,
        ownership: DS4ServerEndpointOwnership = .managed
    ) {
        self.baseURL = baseURL
        self.modelsURL = modelsURL
        self.host = host
        self.port = port
        self.modelID = modelID
        self.processIdentifier = processIdentifier
        self.ownership = ownership
    }

    /// Compatibility spelling for clients that call the advertised id an alias.
    public var modelAlias: String { modelID }

    /// Compatibility spelling for clients that need the process-backed URL.
    public var url: URL { baseURL }

    /// Whether this endpoint was discovered on a pre-existing listener.
    public var isAdopted: Bool { ownership == .adopted }

    /// Whether ZenCODE launched and can safely terminate the process.
    public var isManaged: Bool { ownership == .managed }
}

/// Failures raised while starting or fencing a local ds4 HTTP child.
public enum DS4ServerSupervisorError: LocalizedError, Equatable, Sendable {
    case invalidExecutablePath(String)
    case executableNotFound(String)
    case executableNotRegularFile(String)
    case executableNotExecutable(String)
    case nonLoopbackHost(String)
    case invalidPort(Int)
    case portUnavailable(Int)
    case missingModel
    case invalidModelAlias(String)
    case launchFailed(String)
    case processExited(exitCode: Int32, diagnostics: String)
    case readinessTimedOut(url: String, diagnostics: String)
    case readinessResponseTooLarge(Int)
    case invalidModelsResponse(String)
    case modelAliasMismatch(expected: String, advertised: [String])
    case reservedArgument(String)
    case shutdown

    public var errorDescription: String? {
        switch self {
        case let .invalidExecutablePath(path):
            return "The ds4 executable path must be absolute: \(path)"
        case let .executableNotFound(path):
            return "The ds4 executable was not found: \(path)"
        case let .executableNotRegularFile(path):
            return "The ds4 executable is not a regular file: \(path)"
        case let .executableNotExecutable(path):
            return "The ds4 executable is not executable: \(path)"
        case let .nonLoopbackHost(host):
            return "The ds4 server host must be loopback-only: \(host)"
        case let .invalidPort(port):
            return "The ds4 server port is invalid: \(port)"
        case let .portUnavailable(port):
            return port == 0
                ? "No free loopback port could be selected for the ds4 server."
                : "The ds4 server port is unavailable: \(port)"
        case .missingModel:
            return "The ds4 runtime manifest does not select a model."
        case let .invalidModelAlias(alias):
            return "The ds4 model alias must not be empty: \(alias)"
        case let .launchFailed(message):
            return "The ds4 server could not be launched: \(message)"
        case let .processExited(exitCode, diagnostics):
            if diagnostics.isEmpty {
                return "The ds4 server exited before readiness (exit code \(exitCode))."
            }
            return "The ds4 server exited before readiness (exit code \(exitCode)): \(diagnostics)"
        case let .readinessTimedOut(url, diagnostics):
            if diagnostics.isEmpty {
                return "The ds4 server did not become ready before the deadline (\(url))."
            }
            return "The ds4 server did not become ready before the deadline (\(url)): \(diagnostics)"
        case let .readinessResponseTooLarge(limit):
            return "The ds4 readiness response exceeded the \(limit)-byte limit."
        case let .invalidModelsResponse(message):
            return "The ds4 /v1/models response was invalid: \(message)"
        case let .modelAliasMismatch(expected, advertised):
            let values = advertised.isEmpty ? "<none>" : advertised.joined(separator: ", ")
            return "The ds4 model alias did not match (expected \(expected), advertised \(values))."
        case let .reservedArgument(argument):
            return "The ds4 launch argument is reserved by the supervisor: \(argument)"
        case .shutdown:
            return "The ds4 server supervisor has been shut down."
        }
    }

    /// A bounded diagnostic string suitable for logs and user-facing errors.
    public var diagnostics: String? {
        switch self {
        case let .processExited(_, diagnostics), let .readinessTimedOut(_, diagnostics):
            return diagnostics.isEmpty ? nil : diagnostics
        default:
            return nil
        }
    }
}

/// Actor-isolated lifecycle coordinator for one local ds4 HTTP endpoint.
///
/// The supervisor may adopt one compatible endpoint from its explicit loopback
/// candidate before launching a child. `start()` is single-flight: concurrent
/// callers share one launch/readiness attempt and receive the same endpoint.
/// `stop()` is reusable, while `shutdown()` permanently fences the actor so a
/// cancelled or stale launch can never resurrect a child after its owner has
/// gone away. Adopted endpoints are detached without a process kill.
public actor DS4ServerSupervisor {
    public typealias Error = DS4ServerSupervisorError
    public typealias Endpoint = DS4ServerEndpoint
    public typealias RunningServer = DS4ServerEndpoint

    public static let defaultHost = "127.0.0.1"
    /// The upstream ds4-server default loopback port. This is an adoption
    /// candidate, not a forced launch port; a managed child still falls back
    /// to an ephemeral port when no compatible listener is present.
    public static let defaultConventionalPort = 8_000
    public static let defaultPort = defaultConventionalPort
    public static let defaultAdoptionProbeTimeout: Duration = .milliseconds(250)
    public static let defaultReadinessTimeout: Duration = .seconds(10)
    public static let defaultReadinessPollInterval: Duration = .milliseconds(100)
    public static let defaultMaximumReadinessBodyBytes = 64 * 1_024
    public static let defaultMaximumOutputBytesPerStream = 64 * 1_024

    /// Live settings for a supervisor. The executable is optional so callers
    /// can use the conventional `<root>/ds4-server` or `<root>/ds4` location.
    public struct Configuration: Equatable, Sendable {
        public let manifest: AgentDS4RuntimeManifest
        public let executableURL: URL?
        public let modelAlias: String?
        public let host: String
        /// `nil` or zero selects a free loopback port. A positive value is
        /// reserved and validated before a child is launched.
        public let port: Int?
        /// A bounded, explicit loopback candidate to probe before launching a
        /// child. `nil` disables adoption; by default ds4's conventional port
        /// is probed. This is intentionally not a port scan.
        public let adoptionPort: Int?
        public let adoptionProbeTimeout: Duration
        public let readinessTimeout: Duration
        public let readinessPollInterval: Duration
        public let maximumReadinessBodyBytes: Int
        public let maximumOutputBytesPerStream: Int
        public let terminationGracePeriod: TimeInterval
        public let additionalArguments: [String]

        public init(
            manifest: AgentDS4RuntimeManifest,
            executableURL: URL? = nil,
            modelAlias: String? = nil,
            host: String = DS4ServerSupervisor.defaultHost,
            port: Int? = nil,
            readinessTimeout: Duration = DS4ServerSupervisor.defaultReadinessTimeout,
            readinessPollInterval: Duration = DS4ServerSupervisor.defaultReadinessPollInterval,
            maximumReadinessBodyBytes: Int = DS4ServerSupervisor.defaultMaximumReadinessBodyBytes,
            maximumOutputBytesPerStream: Int = DS4ServerSupervisor.defaultMaximumOutputBytesPerStream,
            terminationGracePeriod: TimeInterval = 2,
            additionalArguments: [String] = [],
            adoptionPort: Int? = DS4ServerSupervisor.defaultConventionalPort,
            adoptionProbeTimeout: Duration = DS4ServerSupervisor.defaultAdoptionProbeTimeout
        ) {
            self.manifest = manifest
            self.executableURL = executableURL
            self.modelAlias = modelAlias?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            self.port = port
            self.adoptionPort = adoptionPort
            self.adoptionProbeTimeout = adoptionProbeTimeout
            self.readinessTimeout = readinessTimeout
            self.readinessPollInterval = readinessPollInterval
            self.maximumReadinessBodyBytes = max(1, maximumReadinessBodyBytes)
            self.maximumOutputBytesPerStream = max(1, maximumOutputBytesPerStream)
            self.terminationGracePeriod = terminationGracePeriod
            self.additionalArguments = additionalArguments
        }

        /// Compatibility spelling for callers that use `modelID` rather than
        /// `modelAlias` in their provider-facing code.
        public init(
            manifest: AgentDS4RuntimeManifest,
            executableURL: URL? = nil,
            modelID: String,
            host: String = DS4ServerSupervisor.defaultHost,
            port: Int? = nil,
            readinessTimeout: Duration = DS4ServerSupervisor.defaultReadinessTimeout,
            readinessPollInterval: Duration = DS4ServerSupervisor.defaultReadinessPollInterval,
            maximumReadinessBodyBytes: Int = DS4ServerSupervisor.defaultMaximumReadinessBodyBytes,
            maximumOutputBytesPerStream: Int = DS4ServerSupervisor.defaultMaximumOutputBytesPerStream,
            terminationGracePeriod: TimeInterval = 2,
            additionalArguments: [String] = [],
            adoptionPort: Int? = DS4ServerSupervisor.defaultConventionalPort,
            adoptionProbeTimeout: Duration = DS4ServerSupervisor.defaultAdoptionProbeTimeout
        ) {
            self.init(
                manifest: manifest,
                executableURL: executableURL,
                modelAlias: modelID,
                host: host,
                port: port,
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                maximumReadinessBodyBytes: maximumReadinessBodyBytes,
                maximumOutputBytesPerStream: maximumOutputBytesPerStream,
                terminationGracePeriod: terminationGracePeriod,
                additionalArguments: additionalArguments,
                adoptionPort: adoptionPort,
                adoptionProbeTimeout: adoptionProbeTimeout
            )
        }
    }

    private struct LaunchResult: Sendable {
        let endpoint: DS4ServerEndpoint
        /// `nil` means the endpoint was adopted and is not killable by
        /// ZenCODE. Never reconstruct a process owner from its port/PID.
        let process: FeatureManagedProcess?
        let launchArguments: [String]
    }

    private let configuration: Configuration
    private let transport: RemoteTransportCore
    private let ownsTransport: Bool

    private var running: LaunchResult?
    private var startTask: Task<LaunchResult, any Swift.Error>?
    private var lastLaunchArguments: [String] = []
    private var lastPort: Int?
    private var shutdownRequested = false
    private var generation: UInt64 = 0
    /// Number of callers currently waiting on the shared startup task. A
    /// cancelled waiter must not cancel that task while another waiter still
    /// depends on the same child.
    private var startWaiterCount = 0
    /// Reset for each launch. It distinguishes a cancelled late joiner from
    /// the sole/all-cancelled startup case when deciding whether to reap a
    /// just-adopted child.
    private var startHasSuccessfulWaiter = false

    /// Creates a supervisor with a process-wide shared transport.
    public init(
        configuration: Configuration,
        transport: RemoteTransportCore? = nil
    ) {
        self.configuration = configuration
        if let transport {
            self.transport = transport
            ownsTransport = false
        } else {
            self.transport = RemoteTransportCore()
            ownsTransport = true
        }
    }

    public init(
        manifest: AgentDS4RuntimeManifest,
        executableURL: URL? = nil,
        modelAlias: String? = nil,
        host: String = DS4ServerSupervisor.defaultHost,
        port: Int? = nil,
        readinessTimeout: Duration = DS4ServerSupervisor.defaultReadinessTimeout,
        readinessPollInterval: Duration = DS4ServerSupervisor.defaultReadinessPollInterval,
        maximumReadinessBodyBytes: Int = DS4ServerSupervisor.defaultMaximumReadinessBodyBytes,
        maximumOutputBytesPerStream: Int = DS4ServerSupervisor.defaultMaximumOutputBytesPerStream,
        terminationGracePeriod: TimeInterval = 2,
        additionalArguments: [String] = [],
        transport: RemoteTransportCore? = nil,
        adoptionPort: Int? = DS4ServerSupervisor.defaultConventionalPort,
        adoptionProbeTimeout: Duration = DS4ServerSupervisor.defaultAdoptionProbeTimeout
    ) {
        self.init(
            configuration: Configuration(
                manifest: manifest,
                executableURL: executableURL,
                modelAlias: modelAlias,
                host: host,
                port: port,
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                maximumReadinessBodyBytes: maximumReadinessBodyBytes,
                maximumOutputBytesPerStream: maximumOutputBytesPerStream,
                terminationGracePeriod: terminationGracePeriod,
                additionalArguments: additionalArguments,
                adoptionPort: adoptionPort,
                adoptionProbeTimeout: adoptionProbeTimeout
            ),
            transport: transport
        )
    }

    /// Compatibility initializer using the provider vocabulary `modelID`.
    public init(
        manifest: AgentDS4RuntimeManifest,
        executableURL: URL? = nil,
        modelID: String,
        host: String = DS4ServerSupervisor.defaultHost,
        port: Int? = nil,
        readinessTimeout: Duration = DS4ServerSupervisor.defaultReadinessTimeout,
        readinessPollInterval: Duration = DS4ServerSupervisor.defaultReadinessPollInterval,
        maximumReadinessBodyBytes: Int = DS4ServerSupervisor.defaultMaximumReadinessBodyBytes,
        maximumOutputBytesPerStream: Int = DS4ServerSupervisor.defaultMaximumOutputBytesPerStream,
        terminationGracePeriod: TimeInterval = 2,
        additionalArguments: [String] = [],
        transport: RemoteTransportCore? = nil,
        adoptionPort: Int? = DS4ServerSupervisor.defaultConventionalPort,
        adoptionProbeTimeout: Duration = DS4ServerSupervisor.defaultAdoptionProbeTimeout
    ) {
        self.init(
            configuration: Configuration(
                manifest: manifest,
                executableURL: executableURL,
                modelID: modelID,
                host: host,
                port: port,
                readinessTimeout: readinessTimeout,
                readinessPollInterval: readinessPollInterval,
                maximumReadinessBodyBytes: maximumReadinessBodyBytes,
                maximumOutputBytesPerStream: maximumOutputBytesPerStream,
                terminationGracePeriod: terminationGracePeriod,
                additionalArguments: additionalArguments,
                adoptionPort: adoptionPort,
                adoptionProbeTimeout: adoptionProbeTimeout
            ),
            transport: transport
        )
    }

    /// Releases the process owner without ever issuing a broad PID/port kill.
    /// The child actor's own bounded TERM → KILL implementation remains the
    /// sole termination path even when the supervisor is abandoned.
    deinit {
        startTask?.cancel()
        if let process = running?.process {
            Task(name: "DS4 server abandoned-child shutdown") {
                await process.stop()
            }
        }
    }

    /// Returns the endpoint for the owned child, if it is currently running.
    public var endpoint: DS4ServerEndpoint? { running?.endpoint }

    /// Compatibility spelling for endpoint-oriented callers.
    public var currentEndpoint: DS4ServerEndpoint? { running?.endpoint }

    public var isRunning: Bool { running != nil }
    public var processIdentifier: Int32? { running?.endpoint.processIdentifier }
    public var port: Int? { running?.endpoint.port ?? lastPort }
    public var host: String { configuration.host }
    public var modelAlias: String? { running?.endpoint.modelID ?? configuration.modelAlias }
    public var launchArguments: [String] { lastLaunchArguments }

    /// Starts the child, or joins the in-flight start already owned by another
    /// caller. Startup is shared independently of waiter cancellation: a
    /// delegated waiter may disappear without cancelling a launch still needed
    /// by another waiter. Explicit ``stop()``/``shutdown()`` remain the only
    /// lifecycle operations that cancel the shared task.
    public func start() async throws -> DS4ServerEndpoint {
        try Task.checkCancellation()
        guard !shutdownRequested else { throw DS4ServerSupervisorError.shutdown }

        if let running {
            if let process = running.process, await process.isRunning {
                return running.endpoint
            }
            if let process = running.process {
                let exit = await process.waitUntilExit()
                self.running = nil
                throw DS4ServerSupervisorError.processExited(
                    exitCode: exit.exitCode,
                    diagnostics: exit.stderr
                )
            }
            // An adopted endpoint has no process handle that ZenCODE can
            // inspect or terminate. It remains reusable until an explicit
            // stop/shutdown detaches this supervisor from it.
            return running.endpoint
        }

        if let startTask {
            do {
                let result = try await awaitStartResult(
                    task: startTask,
                    launchGeneration: generation
                )
                self.startTask = nil
                return result.endpoint
            } catch {
                self.startTask = nil
                throw error
            }
        }

        let launchGeneration = generation
        let configuration = self.configuration
        let transport = self.transport
        let task = Task<LaunchResult, any Swift.Error>(name: "DS4 server startup") {
            try await Self.launch(
                configuration: configuration,
                transport: transport
            )
        }
        startHasSuccessfulWaiter = false
        startTask = task

        do {
            let result = try await awaitStartResult(
                task: task,
                launchGeneration: launchGeneration
            )
            self.startTask = nil
            return result.endpoint
        } catch {
            self.startTask = nil
            throw error
        }
    }

    /// Awaits one shared startup result and adopts it exactly once. The task
    /// value itself is deliberately not wrapped in a cancellation handler that
    /// calls ``Task.cancel()``: doing that lets one sub-agent cancel a launch
    /// still required by another sub-agent.
    private func awaitStartResult(
        task: Task<LaunchResult, any Swift.Error>,
        launchGeneration: UInt64
    ) async throws -> LaunchResult {
        startWaiterCount += 1
        var didReleaseWaiter = false

        do {
            let result = try await task.value
            guard !shutdownRequested, generation == launchGeneration else {
                if let process = result.process {
                    await process.stop()
                }
                startWaiterCount = max(0, startWaiterCount - 1)
                didReleaseWaiter = true
                throw DS4ServerSupervisorError.shutdown
            }

            // A joiner can resume before the task creator gets actor time
            // again, so every waiter is allowed to install the same result.
            if running == nil {
                running = result
                lastLaunchArguments = result.launchArguments
                lastPort = result.endpoint.port
            }

            let cancelled = Task.isCancelled
            if !cancelled {
                startHasSuccessfulWaiter = true
            }
            startWaiterCount = max(0, startWaiterCount - 1)
            didReleaseWaiter = true
            if cancelled {
                // If this was the last waiter, no caller can use the newly
                // launched child. Reap it; otherwise leave it for the waiter
                // that kept the shared startup alive.
                if startWaiterCount == 0, !startHasSuccessfulWaiter, let running,
                   running.endpoint == result.endpoint {
                    if let process = running.process {
                        await process.stop()
                    }
                    self.running = nil
                }
                throw CancellationError()
            }
            return result
        } catch {
            if !didReleaseWaiter {
                startWaiterCount = max(0, startWaiterCount - 1)
            }
            throw error
        }
    }

    /// Alias used by runtime adapters that do not want to distinguish the
    /// first launch from an already-ready child.
    public func ensureRunning() async throws -> DS4ServerEndpoint {
        try await start()
    }

    public func startIfNeeded() async throws -> DS4ServerEndpoint {
        try await start()
    }

    /// Stops only the child owned by this supervisor. It does not search by
    /// port/PID and therefore cannot terminate an unrelated local process.
    /// Unlike `shutdown`, this leaves the supervisor reusable.
    public func stop() async {
        generation &+= 1
        let task = startTask
        task?.cancel()
        if let task {
            _ = try? await task.value
        }
        startTask = nil

        if let running {
            if let process = running.process {
                await process.stop()
            }
            self.running = nil
        }
    }

    /// Permanently fences this owner, cancels any pending launch, stops its
    /// owned child, and optionally closes a transport created by this owner.
    /// Repeated calls join the same idempotent state transition.
    public func shutdown() async {
        if shutdownRequested {
            return
        }
        shutdownRequested = true
        generation &+= 1

        let task = startTask
        task?.cancel()
        if let task {
            _ = try? await task.value
        }
        startTask = nil

        if let running {
            if let process = running.process {
                await process.stop()
            }
            self.running = nil
        }
        if ownsTransport {
            try? await transport.shutdown()
        }
    }

    public func terminate() async {
        await shutdown()
    }

    private static func launch(
        configuration: Configuration,
        transport: RemoteTransportCore
    ) async throws -> LaunchResult {
        try Task.checkCancellation()
        try validateHost(configuration.host)
        try validatePort(configuration.port)
        try validatePort(configuration.adoptionPort)
        guard configuration.readinessTimeout > .zero else {
            throw DS4ServerSupervisorError.readinessTimedOut(url: "/v1/models", diagnostics: "")
        }

        // Resolve the alias before executable/model validation whenever the
        // caller supplied one. An already-running compatible server must be
        // adoptable even when its original local checkout is unavailable.
        let alias: String
        if let configuredAlias = configuration.modelAlias, !configuredAlias.isEmpty {
            alias = try expectedAlias(configuration.modelAlias, modelURL: nil)
        } else {
            let modelURL: URL?
            if configuration.manifest.modelRelativePath == nil {
                modelURL = nil
            } else {
                modelURL = try configuration.manifest.requiredModelURL()
            }
            alias = try expectedAlias(configuration.modelAlias, modelURL: modelURL)
        }

        // Adoption is deliberately limited to the configured candidate and,
        // when different, the explicit launch port. There is no listener/PID
        // scan. A probe failure simply means the managed fallback may launch.
        for candidatePort in adoptionCandidates(configuration) {
            do {
                let endpoint = try await probeEndpoint(
                    process: nil,
                    transport: transport,
                    host: configuration.host,
                    port: candidatePort,
                    alias: alias,
                    timeout: configuration.adoptionProbeTimeout,
                    pollInterval: configuration.readinessPollInterval,
                    maximumBodyBytes: configuration.maximumReadinessBodyBytes
                )
                return LaunchResult(
                    endpoint: DS4ServerEndpoint(
                        baseURL: endpoint.baseURL,
                        modelsURL: endpoint.modelsURL,
                        host: endpoint.host,
                        port: endpoint.port,
                        modelID: endpoint.modelID,
                        ownership: .adopted
                    ),
                    process: nil,
                    launchArguments: []
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as RemoteTransportError {
                if case .shutdown = error {
                    throw error
                }
            } catch {
                // An incompatible, malformed, or unavailable listener is not
                // adopted. If the launch port is occupied, the normal bind
                // path below still reports a collision without killing it.
            }
        }

        let executableURL = try canonicalExecutableURL(
            configuration.executableURL,
            rootDirectory: configuration.manifest.rootDirectory
        )
        let modelURL: URL?
        if configuration.manifest.modelRelativePath == nil {
            modelURL = nil
        } else {
            modelURL = try configuration.manifest.requiredModelURL()
        }

        // A dynamic port can be retried after an immediate EADDRINUSE crash;
        // fixed ports are deliberately attempted once so callers get a clear
        // collision error rather than repeatedly touching a user-selected port.
        let attemptCount = normalizedPort(configuration.port) == nil ? 3 : 1
        var lastFailure: DS4ServerSupervisorError?

        for attempt in 0..<attemptCount {
            try Task.checkCancellation()
            let reservation: DS4PortReservation
            do {
                reservation = try DS4PortReservation.bind(
                    host: configuration.host,
                    requestedPort: normalizedPort(configuration.port)
                )
            } catch {
                let requested = normalizedPort(configuration.port) ?? 0
                throw DS4ServerSupervisorError.portUnavailable(requested)
            }
            let port = reservation.port
            // The reservation prevents selection of an already-listening port.
            // Process.run cannot inherit the reservation because ds4 must bind
            // itself, so release it immediately before the direct launch and
            // recover from the narrow remaining race by retrying auto ports.
            reservation.release()

            let arguments = try makeArguments(
                configuration: configuration,
                modelURL: modelURL,
                port: port
            )
            let process = FeatureManagedProcess(
                executableURL: executableURL,
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: configuration.manifest.rootDirectory),
                maximumOutputBytesPerStream: configuration.maximumOutputBytesPerStream,
                terminationGracePeriod: configuration.terminationGracePeriod
            )

            do {
                try await process.start()
                let endpoint = try await probeEndpoint(
                    process: process,
                    transport: transport,
                    host: configuration.host,
                    port: port,
                    alias: alias,
                    timeout: configuration.readinessTimeout,
                    pollInterval: configuration.readinessPollInterval,
                    maximumBodyBytes: configuration.maximumReadinessBodyBytes
                )
                return LaunchResult(
                    endpoint: DS4ServerEndpoint(
                        baseURL: endpoint.baseURL,
                        modelsURL: endpoint.modelsURL,
                        host: endpoint.host,
                        port: endpoint.port,
                        modelID: endpoint.modelID,
                        processIdentifier: await process.processIdentifier,
                        ownership: .managed
                    ),
                    process: process,
                    launchArguments: arguments
                )
            } catch is CancellationError {
                await process.stop()
                throw CancellationError()
            } catch let error as DS4ServerSupervisorError {
                await process.stop()
                if case let .processExited(code, diagnostics) = error,
                   normalizedPort(configuration.port) == nil,
                   attempt + 1 < attemptCount,
                   code != 0 {
                    lastFailure = .processExited(exitCode: code, diagnostics: diagnostics)
                    continue
                }
                throw error
            } catch {
                await process.stop()
                throw DS4ServerSupervisorError.launchFailed(String(describing: error))
            }
        }

        throw lastFailure ?? DS4ServerSupervisorError.portUnavailable(0)
    }

    private static func probeEndpoint(
        process: FeatureManagedProcess?,
        transport: RemoteTransportCore,
        host: String,
        port: Int,
        alias: String,
        timeout: Duration,
        pollInterval: Duration,
        maximumBodyBytes: Int
    ) async throws -> DS4ServerEndpoint {
        let baseURL = try makeURL(host: host, port: port, path: "/v1")
        let modelsURL = try makeURL(host: host, port: port, path: "/v1/models")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let poll = pollInterval > .zero ? pollInterval : .milliseconds(1)
        let idleNanoseconds = durationNanoseconds(poll)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let process {
                if !(await process.isRunning) {
                    let exit = await process.waitUntilExit()
                    throw DS4ServerSupervisorError.processExited(
                        exitCode: exit.exitCode,
                        diagnostics: exit.stderr
                    )
                }
            }

            let remaining = deadline - .now
            let requestTimeout = remaining < poll ? remaining : poll
            do {
                let response = try await transport.openHTTPStream(
                    RemoteHTTPStreamingRequest(
                        url: modelsURL,
                        timeout: requestTimeout
                    )
                )
                if response.status == 200 {
                    let body = try await collectProbeBody(
                        response.body,
                        deadline: deadline,
                        idleNanoseconds: idleNanoseconds,
                        maximumBodyBytes: maximumBodyBytes
                    )
                    let advertised = try decodeModelIDs(body)
                    guard advertised.contains(alias) else {
                        throw DS4ServerSupervisorError.modelAliasMismatch(
                            expected: alias,
                            advertised: advertised
                        )
                    }
                    return DS4ServerEndpoint(
                        baseURL: baseURL,
                        modelsURL: modelsURL,
                        host: host,
                        port: port,
                        modelID: alias
                    )
                }
                // Non-200 responses are readiness misses. The response body
                // is intentionally not collected, keeping probes bounded.
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DS4ServerSupervisorError {
                throw error
            } catch let error as RemoteTransportError {
                // Connection refused, an early close, and a per-probe timeout
                // are normal while ds4 is loading. The outer deadline bounds
                // every retry and the process check above catches a crash.
                switch error {
                case .shutdown:
                    throw error
                default:
                    break
                }
            } catch {
                // A malformed/incomplete probe is treated as not-ready until
                // the same bounded deadline; process stderr remains diagnostic.
            }

            if poll > .zero, ContinuousClock.now < deadline {
                do {
                    let remaining = deadline - .now
                    let sleepDuration = remaining < poll ? remaining : poll
                    guard sleepDuration > .zero else { break }
                    try await Task.sleep(for: sleepDuration)
                } catch {
                    throw CancellationError()
                }
            }
        }

        let diagnostics = if let process {
            await process.diagnostics()
        } else {
            ""
        }
        throw DS4ServerSupervisorError.readinessTimedOut(
            url: modelsURL.absoluteString,
            diagnostics: diagnostics
        )
    }

    /// Drains one readiness response under the probe's absolute wall-clock
    /// deadline. The transport request timeout only covers response-head
    /// acquisition, and the body's idle watchdog alone can be defeated by a
    /// listener that sends a trickle of bytes before each idle interval.
    /// Racing the complete drain against the remaining deadline keeps that
    /// listener from extending a probe indefinitely. Cancelling the body on
    /// every terminal path releases its channel/lifetime even when the read
    /// task is still parked in NIO.
    private static func collectProbeBody(
        _ body: RemoteHTTPBody,
        deadline: ContinuousClock.Instant,
        idleNanoseconds: UInt64,
        maximumBodyBytes: Int
    ) async throws -> Data {
        let remaining = deadline - .now
        guard remaining > .zero else {
            body.cancel()
            throw RemoteTransportError.timeout
        }

        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var collected = Data()
                    var iterator = body.makeAsyncIterator()
                    while let chunk = try await iterator.next(
                        idleTimeoutNanoseconds: idleNanoseconds
                    ) {
                        // Check the incoming chunk before subtracting from the
                        // limit. A single oversized chunk must report the
                        // bounded-body error, never trap from Int underflow.
                        guard chunk.count <= maximumBodyBytes else {
                            throw DS4ServerSupervisorError.readinessResponseTooLarge(
                                maximumBodyBytes
                            )
                        }
                        guard collected.count <= maximumBodyBytes - chunk.count else {
                            throw DS4ServerSupervisorError.readinessResponseTooLarge(
                                maximumBodyBytes
                            )
                        }
                        collected.append(chunk)
                    }
                    return collected
                }
                group.addTask {
                    try await Task.sleep(for: remaining)
                    throw RemoteTransportError.timeout
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw RemoteTransportError.timeout
                }
                return result
            }
        } catch {
            // `RemoteHTTPBody.AsyncIterator.next` also reacts to task
            // cancellation, but invalidate explicitly so no copied response
            // handle can keep the timed-out channel alive.
            body.cancel()
            throw error
        }
    }

    private static func adoptionCandidates(_ configuration: Configuration) -> [Int] {
        guard configuration.adoptionPort != nil else {
            return []
        }
        var candidates: [Int] = []
        if let adoptionPort = normalizedPort(configuration.adoptionPort) {
            candidates.append(adoptionPort)
        }
        if let launchPort = normalizedPort(configuration.port), !candidates.contains(launchPort) {
            candidates.append(launchPort)
        }
        return candidates
    }

    private static func decodeModelIDs(_ body: Data) throws -> [String] {
        struct Models: Decodable {
            struct Entry: Decodable { let id: String }
            let data: [Entry]
        }
        do {
            return try JSONDecoder().decode(Models.self, from: body).data.map(\.id)
        } catch {
            throw DS4ServerSupervisorError.invalidModelsResponse(
                String(decoding: body.prefix(512), as: UTF8.self)
            )
        }
    }

    private static func makeArguments(
        configuration: Configuration,
        modelURL: URL?,
        port: Int
    ) throws -> [String] {
        var arguments = [
            "--host", configuration.host,
            "--port", String(port),
            "--ctx", String(configuration.manifest.contextWindow),
            "--power", String(configuration.manifest.power)
        ]
        if let modelURL {
            arguments += ["-m", modelURL.path]
        }
        switch configuration.manifest.backend {
        case .metal:
            arguments.append("--metal")
        case .cuda:
            arguments.append("--cuda")
        case .rocm:
            arguments += ["--backend", "rocm"]
        case .cpu:
            arguments.append("--cpu")
        }
        if configuration.manifest.batchedSessions {
            arguments += ["--batched-session", "1"]
        }
        if configuration.manifest.ssdStreaming {
            arguments.append("--ssd-streaming")
            if configuration.manifest.ssdStreamingCold {
                arguments.append("--ssd-streaming-cold")
            }
            if let cacheExperts = configuration.manifest.ssdStreamingCacheExperts {
                arguments += ["--ssd-streaming-cache-experts", String(cacheExperts)]
            } else if let cacheBytes = configuration.manifest.ssdStreamingCacheBytes {
                // ds4 accepts a decimal GB suffix for byte-sized SSD caches.
                let bytesPerGigabyte: UInt64 = 1_073_741_824
                let gigabytes = max(
                    UInt64(1),
                    cacheBytes / bytesPerGigabyte
                        + (cacheBytes % bytesPerGigabyte == 0 ? 0 : 1)
                )
                arguments += ["--ssd-streaming-cache-experts", "\(gigabytes)GB"]
            }
            if let preloadExperts = configuration.manifest.ssdStreamingPreloadExperts {
                arguments += ["--ssd-streaming-preload-experts", String(preloadExperts)]
            }
        }
        if configuration.manifest.mtp {
            arguments.append("--mtp")
        }
        // Additional arguments are still individual argv entries; they are
        // never interpolated into a shell command. Supervisor-owned flags are
        // rejected rather than appended after the canonical values, because
        // ds4 parsers commonly use the last occurrence as the effective one.
        try validateAdditionalArguments(configuration.additionalArguments)
        arguments += configuration.additionalArguments
        return arguments
    }

    private static let reservedAdditionalArgumentFlags: Set<String> = [
        "--",
        "-h", "--help",
        "-p", "--port",
        "--host", "--bind", "--listen", "--address",
        "-m", "--model", "--model-path", "--model-file", "--load-model",
        "--vision", "--mtp-model",
        "--alias",
        "--chdir", "--cwd", "--workdir", "--working-directory",
        "--root", "--root-directory",
        "-c", "--ctx", "--context", "--context-size",
        "--mtp", "--power",
        "--trace", "--kv-disk-dir", "--dir-steering-file",
        "--backend", "--metal", "--cuda", "--rocm", "--cpu",
        "--batched-session", "--ssd-streaming", "--ssd-streaming-cold",
        "--ssd-streaming-cache-experts", "--ssd-streaming-preload-experts",
        "--ssd-streaming-full-layers",
        "--server"
    ]

    private static func validateAdditionalArguments(_ arguments: [String]) throws {
        for argument in arguments {
            let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
            let flag = String(trimmed.split(separator: "=", maxSplits: 1).first ?? "")
            if reservedAdditionalArgumentFlags.contains(trimmed)
                || reservedAdditionalArgumentFlags.contains(flag)
                || isSecuritySensitiveAdditionalFlag(flag) {
                throw DS4ServerSupervisorError.reservedArgument(argument)
            }
        }
    }

    private static func isSecuritySensitiveAdditionalFlag(_ flag: String) -> Bool {
        let normalized = flag.lowercased()
        guard normalized.hasPrefix("--") else { return false }
        let families = [
            "host", "port", "model", "chdir", "cwd", "workdir", "root",
            "path", "dir", "file", "bind", "listen", "address", "backend",
            "ctx", "context", "streaming", "server", "alias", "distributed",
            "tensor-parallel"
        ]
        return families.contains { family in
            normalized == "--\(family)" || normalized.hasPrefix("--\(family)-")
        }
    }

    private static func expectedAlias(
        _ configured: String?,
        modelURL: URL?
    ) throws -> String {
        if let configured {
            guard !configured.isEmpty else {
                throw DS4ServerSupervisorError.invalidModelAlias(configured)
            }
            return DS4ModelCatalog.canonicalAPIModelID(forCatalogID: configured)
        }
        if let modelURL {
            let stem = modelURL.deletingPathExtension().lastPathComponent
            if !stem.isEmpty {
                switch stem.lowercased() {
                case "ds4flash", "ds4-flash", "deepseek-v4-flash":
                    return "deepseek-v4-flash"
                case "ds4pro", "ds4-pro", "deepseek-v4-pro":
                    return "deepseek-v4-pro"
                default:
                    return stem
                }
            }
        }
        // A manifest without a model is useful for deterministic fixture
        // servers; the real runtime normally always supplies one.
        return "deepseek-v4"
    }

    private static func validateHost(_ host: String) throws {
        let normalized = host.lowercased()
        guard normalized == "127.0.0.1"
            || normalized == "localhost"
            || normalized == "::1"
        else {
            throw DS4ServerSupervisorError.nonLoopbackHost(host)
        }
    }

    private static func validatePort(_ port: Int?) throws {
        guard let port else { return }
        guard port == 0 || (1...65_535).contains(port) else {
            throw DS4ServerSupervisorError.invalidPort(port)
        }
    }

    private static func normalizedPort(_ port: Int?) -> Int? {
        guard let port, port != 0 else { return nil }
        return port
    }

    private static func canonicalExecutableURL(
        _ supplied: URL?,
        rootDirectory: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let candidates: [URL]
        if let supplied {
            candidates = [supplied]
        } else {
            let root = URL(fileURLWithPath: rootDirectory, isDirectory: true)
            candidates = [
                root.appendingPathComponent("ds4-server"),
                root.appendingPathComponent("ds4"),
                root.appendingPathComponent("bin/ds4-server"),
                root.appendingPathComponent("bin/ds4")
            ]
        }

        for candidate in candidates {
            let raw = candidate.path
            guard raw.hasPrefix("/") else {
                if supplied != nil {
                    throw DS4ServerSupervisorError.invalidExecutablePath(raw)
                }
                continue
            }
            let canonical = candidate.standardizedFileURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: canonical.path, isDirectory: &isDirectory) else {
                continue
            }
            guard !isDirectory.boolValue else {
                if supplied != nil {
                    throw DS4ServerSupervisorError.executableNotRegularFile(canonical.path)
                }
                continue
            }
            guard fileManager.isExecutableFile(atPath: canonical.path) else {
                throw DS4ServerSupervisorError.executableNotExecutable(canonical.path)
            }
            return canonical
        }

        let missing = candidates.first?.standardizedFileURL.path ?? rootDirectory
        throw DS4ServerSupervisorError.executableNotFound(missing)
    }

    private static func makeURL(host: String, port: Int, path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        guard let url = components.url else {
            throw DS4ServerSupervisorError.launchFailed("Could not construct loopback URL.")
        }
        return url
    }

    private static func durationNanoseconds(_ duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds > 0 || components.attoseconds > 0 else { return 1 }
        let seconds = UInt64(max(0, components.seconds))
        let nanos = UInt64(max(0, components.attoseconds) / 1_000_000_000)
        return seconds.multipliedReportingOverflow(by: 1_000_000_000).overflow
            ? UInt64.max
            : seconds * 1_000_000_000 + nanos
    }
}

/// A short-lived loopback listener used only to choose/reserve a port before a
/// child launch. It never owns or terminates a process.
private final class DS4PortReservation: @unchecked Sendable {
    let port: Int
    private var fileDescriptor: Int32?

    private init(fileDescriptor: Int32, port: Int) {
        self.fileDescriptor = fileDescriptor
        self.port = port
    }

    static func bind(host: String, requestedPort: Int?) throws -> DS4PortReservation {
        #if os(macOS) || os(Linux)
        if host.lowercased() == "::1" {
            return try bindIPv6(requestedPort: requestedPort)
        }
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXPortError.bindFailed }
        var address = sockaddr_in()
        #if os(macOS)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(requestedPort ?? 0).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in>.size)
                )
            }
        }
        guard result == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        guard DarwinOrGlibc.listen(fileDescriptor, 1) == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let assignedResult = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.getsockname(fileDescriptor, $0, &length)
            }
        }
        guard assignedResult == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        let port = Int(UInt16(bigEndian: assigned.sin_port))
        guard port > 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        return DS4PortReservation(fileDescriptor: fileDescriptor, port: port)
        #else
        _ = host
        _ = requestedPort
        throw POSIXPortError.unsupported
        #endif
    }

    #if os(macOS) || os(Linux)
    private static func bindIPv6(requestedPort: Int?) throws -> DS4PortReservation {
        let fileDescriptor = socket(AF_INET6, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw POSIXPortError.bindFailed }
        var address = sockaddr_in6()
        #if os(macOS)
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        #endif
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = UInt16(requestedPort ?? 0).bigEndian
        var loopbackAddress = in6_addr()
        withUnsafeMutableBytes(of: &loopbackAddress) { bytes in
            for index in bytes.indices {
                bytes[index] = 0
            }
            bytes[15] = 1
        }
        address.sin6_addr = loopbackAddress
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_in6>.size)
                )
            }
        }
        guard result == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        guard DarwinOrGlibc.listen(fileDescriptor, 1) == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        var assigned = sockaddr_in6()
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let assignedResult = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                DarwinOrGlibc.getsockname(fileDescriptor, $0, &length)
            }
        }
        guard assignedResult == 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        let port = Int(UInt16(bigEndian: assigned.sin6_port))
        guard port > 0 else {
            DarwinOrGlibc.close(fileDescriptor)
            throw POSIXPortError.bindFailed
        }
        return DS4PortReservation(fileDescriptor: fileDescriptor, port: port)
    }
    #endif

    func release() {
        guard let fileDescriptor else { return }
        self.fileDescriptor = nil
        DarwinOrGlibc.close(fileDescriptor)
    }

    deinit { release() }
}

private enum POSIXPortError: Error {
    case bindFailed
    case unsupported
}

#if os(macOS)
private enum DarwinOrGlibc {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Darwin.bind(fd, address, length)
    }
    static func getsockname(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Darwin.getsockname(fd, address, length)
    }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Darwin.listen(fd, backlog) }
    static func close(_ fd: Int32) { _ = Darwin.close(fd) }
}
#elseif os(Linux)
private enum DarwinOrGlibc {
    static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
        Glibc.bind(fd, address, length)
    }
    static func getsockname(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 {
        Glibc.getsockname(fd, address, length)
    }
    static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    static func close(_ fd: Int32) { _ = Glibc.close(fd) }
}
#else
private enum DarwinOrGlibc {
    static func close(_ fd: Int32) { _ = fd }
}
#endif
