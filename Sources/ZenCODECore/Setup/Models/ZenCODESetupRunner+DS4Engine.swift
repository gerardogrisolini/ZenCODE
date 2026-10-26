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
        let emit: @Sendable (String) -> Void = engine.output ?? { line in
            AgentOutput.standardError.writeString(line + "\n")
        }

        var targets: [DS4EngineTarget] = []
        for runtime in runtimes {
            let target = DS4EngineTarget(runtime: runtime)
            if !targets.contains(target) {
                targets.append(target)
            }
        }

        var pending: [(target: DS4EngineTarget, request: DS4EngineBuildRequest)] = []
        for target in targets {
            // Without ds4.h the library location cannot be derived and the build
            // would fail on it: say so instead of asking.
            do {
                _ = try DS4EngineLibraryLocator.expectedURL(
                    rootDirectory: target.rootDirectory,
                    backend: target.backend,
                    supportDirectory: supportDirectory
                )
            } catch {
                emit("DS4 engine (\(target.displayName)) not built: \(error.localizedDescription)")
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

        for (target, request) in pending {
            try Task.checkCancellation()
            emit("==> Building the DS4 engine (\(target.displayName))")
            do {
                let library = try await engine.builder.build(request, output: emit)
                emit("DS4 engine built (\(target.displayName)): \(library.path)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reportDS4EngineBuildFailure(error, target: target, request: request, emit: emit)
            }
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
