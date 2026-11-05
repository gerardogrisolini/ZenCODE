//
//  ZenCODESetupRunner+DS4Engine.swift
//  ZenCODE
//
//  Builds the in-process DS4 engine library at the end of the DS4 setup stage.
//

import Foundation

/// One engine library the setup may have to build: DS4 checkout, backend and
/// GPU architecture. Models that share all three share one library.
struct DS4EngineTarget: Hashable, Sendable {
    let rootDirectory: String
    let backend: AgentDS4RuntimeBackend
    /// Architecture the build records: the chosen one or the backend default for
    /// CUDA and ROCm, `nil` for the other backends.
    let arch: String?

    init(runtime: AgentDS4RuntimeManifest) {
        let requested: String?
        switch runtime.backend {
        case .cuda: requested = runtime.cudaArch
        case .rocm: requested = runtime.rocmArch
        case .metal, .cpu: requested = nil
        }
        self.rootDirectory = runtime.rootDirectory
        self.backend = runtime.backend
        self.arch = DS4EngineLibraryLocator.effectiveArch(backend: runtime.backend, arch: requested)
    }

    /// `metal`, or `cuda sm_120` for the GPU backends.
    var displayName: String {
        guard let arch else { return backend.rawValue }
        return "\(backend.rawValue) \(arch)"
    }

    func buildRequest(supportDirectory: URL) -> DS4EngineBuildRequest {
        DS4EngineBuildRequest(
            rootDirectory: rootDirectory,
            backend: backend,
            cudaArch: backend == .cuda ? arch : nil,
            rocmArch: backend == .rocm ? arch : nil,
            supportDirectory: supportDirectory
        )
    }
}

extension ZenCODESetupRunner {
    /// `built`, `missing` or `rebuild required`, for the setup menu.
    static func ds4EngineStateDescription(
        for target: DS4EngineTarget,
        supportDirectory: URL
    ) -> String {
        switch DS4EngineLibraryLocator.status(
            rootDirectory: target.rootDirectory,
            backend: target.backend,
            arch: target.arch,
            supportDirectory: supportDirectory
        ) {
        case .built: return "built"
        case .missing: return "missing"
        case .stale: return "rebuild required"
        }
    }

    /// Builds the engine library for every distinct DS4 folder, backend and
    /// architecture of `runtimes` whose library is not already built.
    ///
    /// The question is asked once, however many libraries are pending. A build
    /// failure is reported (error plus the command that repeats the build by
    /// hand) and never thrown, so it cannot cancel the setup transaction;
    /// only cancellation (Esc at the question, task cancellation) propagates.
    static func buildDS4EngineIfNeeded(
        runtimes: [AgentDS4RuntimeManifest],
        engine: DS4SetupEngineOptions
    ) async throws {
        let supportDirectory = engine.supportDirectory ?? AppStorageDirectory.appSupportDirectoryURL()
        let emit = ds4EngineOutput(engine)

        var pending: [(target: DS4EngineTarget, request: DS4EngineBuildRequest)] = []
        for target in distinctDS4EngineTargets(of: runtimes) {
            // Without ds4.h the library location cannot be derived and the build
            // would fail on it: say so instead of asking.
            guard canLocateDS4Engine(target, supportDirectory: supportDirectory, emit: emit) else {
                continue
            }
            switch DS4EngineLibraryLocator.status(
                rootDirectory: target.rootDirectory,
                backend: target.backend,
                arch: target.arch,
                supportDirectory: supportDirectory
            ) {
            case let .built(url):
                emit("DS4 engine already built (\(target.displayName)): \(url.path)")
            case .missing:
                pending.append((target, target.buildRequest(supportDirectory: supportDirectory)))
            case .stale:
                emit("DS4 engine (\(target.displayName)) is out of date and must be rebuilt.")
                pending.append((target, target.buildRequest(supportDirectory: supportDirectory)))
            }
        }
        guard !pending.isEmpty else {
            return
        }

        let requests = pending.map(\.request)
        let shouldBuild = try engine.confirmBuild?(requests) ?? promptYesNo(
            "Build the DS4 engine now?",
            defaultValue: true,
            help: "ZenCODE runs DS4 in-process through libzencode-ds4, a small library compiled against your DS4 checkout (\(pending.map(\.target.displayName).joined(separator: ", "))). The build only recompiles DS4 object files in the checkout and never overwrites its binaries; you can also run it later from this setup."
        )
        guard shouldBuild else {
            emit("DS4 engine build skipped. Run the DS4 setup again to build it before using DS4.")
            return
        }

        try await runDS4EngineBuilds(pending, mode: .build, engine: engine, emit: emit)
    }

    /// Rebuilds the engine library of every distinct DS4 folder, backend and
    /// architecture of `runtimes`, even when it is already built. This is the
    /// manual "Rebuild the DS4 engine" setup entry: it is the way to pick up a
    /// change to the DS4 sources that the library check cannot see (for example
    /// an updated `ds4.c`), so it asks nothing; choosing the entry is the
    /// confirmation.
    ///
    /// A folder without `ds4.h` is reported and skipped. A build failure is
    /// reported (error plus the command that repeats the build by hand) and
    /// never thrown; only cancellation (task cancellation) propagates.
    static func rebuildDS4Engines(
        runtimes: [AgentDS4RuntimeManifest],
        engine: DS4SetupEngineOptions
    ) async throws {
        let supportDirectory = engine.supportDirectory ?? AppStorageDirectory.appSupportDirectoryURL()
        let emit = ds4EngineOutput(engine)

        var jobs: [(target: DS4EngineTarget, request: DS4EngineBuildRequest)] = []
        for target in distinctDS4EngineTargets(of: runtimes) {
            guard canLocateDS4Engine(target, supportDirectory: supportDirectory, emit: emit) else {
                continue
            }
            jobs.append((target, target.buildRequest(supportDirectory: supportDirectory)))
        }
        try await runDS4EngineBuilds(jobs, mode: .rebuild, engine: engine, emit: emit)
    }

    /// How `runDS4EngineBuilds` words its progress lines.
    private enum DS4EngineBuildMode {
        case build
        case rebuild

        func startLine(_ target: DS4EngineTarget) -> String {
            switch self {
            case .build: return "==> Building the DS4 engine (\(target.displayName))"
            case .rebuild: return "==> Rebuilding the DS4 engine (\(target.displayName))"
            }
        }

        func successLine(_ target: DS4EngineTarget, library: URL) -> String {
            switch self {
            case .build: return "DS4 engine built (\(target.displayName)): \(library.path)"
            case .rebuild: return "DS4 engine rebuilt (\(target.displayName)): \(library.path)"
            }
        }
    }

    /// Builds the given libraries one after the other. A failure is reported
    /// and the next library is still built; only cancellation propagates.
    private static func runDS4EngineBuilds(
        _ jobs: [(target: DS4EngineTarget, request: DS4EngineBuildRequest)],
        mode: DS4EngineBuildMode,
        engine: DS4SetupEngineOptions,
        emit: @escaping @Sendable (String) -> Void
    ) async throws {
        for (target, request) in jobs {
            try Task.checkCancellation()
            emit(mode.startLine(target))
            do {
                let library = try await engine.builder.build(request, output: emit)
                emit(mode.successLine(target, library: library))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reportDS4EngineBuildFailure(error, target: target, request: request, emit: emit)
            }
        }
    }

    /// Where the setup prints the lines about the engine, including the build log.
    private static func ds4EngineOutput(
        _ engine: DS4SetupEngineOptions
    ) -> @Sendable (String) -> Void {
        engine.output ?? { line in
            AgentOutput.standardError.writeString(line + "\n")
        }
    }

    /// The distinct targets of `runtimes`, in order of first appearance. Models
    /// that share folder, backend and architecture share one library.
    private static func distinctDS4EngineTargets(
        of runtimes: [AgentDS4RuntimeManifest]
    ) -> [DS4EngineTarget] {
        var targets: [DS4EngineTarget] = []
        for runtime in runtimes {
            let target = DS4EngineTarget(runtime: runtime)
            if !targets.contains(target) {
                targets.append(target)
            }
        }
        return targets
    }

    /// Whether the library location of `target` can be derived. Without `ds4.h`
    /// it cannot: the reason is emitted and the target must be skipped.
    private static func canLocateDS4Engine(
        _ target: DS4EngineTarget,
        supportDirectory: URL,
        emit: @Sendable (String) -> Void
    ) -> Bool {
        do {
            _ = try DS4EngineLibraryLocator.expectedURL(
                rootDirectory: target.rootDirectory,
                backend: target.backend,
                supportDirectory: supportDirectory
            )
            return true
        } catch {
            emit("DS4 engine (\(target.displayName)) not built: \(error.localizedDescription)")
            return false
        }
    }

    private static func reportDS4EngineBuildFailure(
        _ error: any Error,
        target: DS4EngineTarget,
        request: DS4EngineBuildRequest,
        emit: @Sendable (String) -> Void
    ) {
        let message = error.localizedDescription
        emit("DS4 engine build failed (\(target.displayName)): \(message)")

        // These fail before the build script is written, so a command that runs
        // it would not exist yet.
        if let buildError = error as? DS4EngineBuildError {
            switch buildError {
            case .unsupportedPlatform, .invalidArchitecture, .shimExtractionFailed:
                emit("The DS4 configuration is kept; fix the problem and run the DS4 setup again.")
                return
            default:
                break
            }
        }
        let manualCommand = DS4EngineBuilder.manualCommand(for: request)
        if !message.contains(manualCommand) {
            emit("Run the build manually with:\n\(manualCommand)")
        }
        emit("The DS4 configuration is kept; build the engine before using DS4.")
    }
}
