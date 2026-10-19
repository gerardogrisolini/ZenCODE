//
//  DS4ServerSupervisor+Launch.swift
//  ZenCODE
//

import FeatureKit
import Foundation

extension DS4ServerSupervisor {
    static func launch(
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

        // A supplied alias is resolved before executable/model validation so a running
        // compatible server stays adoptable without its local checkout.
        let hasConfiguredAlias = configuration.modelAlias?.isEmpty == false
        let alias = try expectedAlias(
            configuration.modelAlias,
            modelURL: hasConfiguredAlias ? nil : resolvedModelURL(configuration)
        )

        // Adoption is limited to the configured candidate and the explicit launch
        // port (no listener/PID scan); a probe failure falls back to a managed launch.
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
                    endpoint: endpoint.replacing(processIdentifier: nil, ownership: .adopted),
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
                // Not adopted; an occupied launch port is still reported by the bind path below.
            }
        }

        let executableURL = try canonicalExecutableURL(
            configuration.executableURL,
            rootDirectory: configuration.manifest.rootDirectory
        )
        let modelURL = try resolvedModelURL(configuration)

        // Dynamic ports are retried after an immediate EADDRINUSE crash; fixed ports
        // are attempted once so callers get a clear collision error.
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
            // ds4 must bind the port itself, so release the reservation right before
            // launch and retry auto ports on the remaining narrow race.
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
                    endpoint: endpoint.replacing(
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

    private static func resolvedModelURL(_ configuration: Configuration) throws -> URL? {
        configuration.manifest.modelRelativePath == nil
            ? nil
            : try configuration.manifest.requiredModelURL()
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
            if let process, !(await process.isRunning) {
                let exit = await process.waitUntilExit()
                throw DS4ServerSupervisorError.processExited(
                    exitCode: exit.exitCode,
                    diagnostics: exit.stderr
                )
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
                // Refused/closed/timed-out probes are normal while ds4 loads; the deadline bounds retries.
                if case .shutdown = error { throw error }
            } catch {
                // A malformed probe is not-ready until the deadline.
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

    /// Drains one readiness response under the probe's absolute deadline. The
    /// transport timeout covers only the response head and the idle watchdog can
    /// be defeated by a trickling listener, so the whole drain races the remaining
    /// deadline. The body is cancelled on every terminal path to release its channel.
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
                        // Check the chunk first so an oversized one never underflows the limit.
                        guard chunk.count <= maximumBodyBytes,
                              collected.count <= maximumBodyBytes - chunk.count else {
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
            // Invalidate explicitly so no copied response handle keeps the channel alive.
            body.cancel()
            throw error
        }
    }

    private static func adoptionCandidates(_ configuration: Configuration) -> [Int] {
        guard let adoptionPort = configuration.adoptionPort else { return [] }
        var candidates = [normalizedPort(adoptionPort)].compactMap { $0 }
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
        // Individual argv entries, never shell-interpolated. Supervisor-owned flags
        // are rejected because ds4 parsers usually honour the last occurrence.
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
        // A model-less manifest serves deterministic fixture servers.
        return "deepseek-v4"
    }

    private static func validateHost(_ host: String) throws {
        let normalized = host.lowercased()
        guard ["127.0.0.1", "localhost", "::1"].contains(normalized) else {
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
