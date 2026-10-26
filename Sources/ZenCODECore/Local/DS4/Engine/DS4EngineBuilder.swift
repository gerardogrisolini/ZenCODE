//
//  DS4EngineBuilder.swift
//  ZenCODE
//
//  Builds `libzencode-ds4.{dylib,so}` on the user's machine: extracts the
//  embedded shim sources and `build-ds4-engine.sh` into `<support>/ds4/shim/`,
//  runs the script against the user's DS4 checkout, then checks that the
//  library loads and reports the expected ABI version.
//

import Foundation

/// What to build: the DS4 checkout, the backend and the GPU architecture.
struct DS4EngineBuildRequest: Sendable, Equatable {
    let rootDirectory: String
    let backend: AgentDS4RuntimeBackend
    /// `nvcc` architecture for the CUDA backend (`nil` builds for `native`).
    let cudaArch: String?
    /// ROCm target for the ROCm backend (`nil` builds for `gfx1151`).
    let rocmArch: String?
    let supportDirectory: URL
}

/// Seam used by the DS4 setup to build the engine; tests substitute a fake.
protocol DS4EngineBuilding: Sendable {
    /// Builds the engine library and returns its URL. `output` receives the
    /// build log line by line. Throws `DS4EngineBuildError` on failure.
    func build(
        _ request: DS4EngineBuildRequest,
        output: @escaping @Sendable (String) -> Void
    ) async throws -> URL
}

enum DS4EngineBuildError: LocalizedError, Equatable, Sendable {
    case unsupportedPlatform(backend: AgentDS4RuntimeBackend)
    case invalidArchitecture(String)
    case shimExtractionFailed(path: String, reason: String)
    case launchFailed(reason: String, manualCommand: String)
    case buildFailed(exitCode: Int32, manualCommand: String)
    case libraryNotProduced(path: String)
    case libraryLoadFailed(path: String, reason: String)
    case abiSymbolMissing(path: String)
    case abiVersionMismatch(path: String, found: Int32, expected: Int32)

    var errorDescription: String? {
        switch self {
        case let .unsupportedPlatform(backend):
            return "The \(backend.rawValue) backend cannot be built on this operating system."
        case let .invalidArchitecture(value):
            return "Invalid GPU architecture '\(value)': use letters, digits and _ . + : - only."
        case let .shimExtractionFailed(path, reason):
            return "Could not write the DS4 engine sources to \(path): \(reason)"
        case let .launchFailed(reason, manualCommand):
            return "Could not start the DS4 engine build: \(reason)\nRun it manually with:\n\(manualCommand)"
        case let .buildFailed(exitCode, manualCommand):
            return "The DS4 engine build failed (exit status \(exitCode)). Run it manually to see the full log:\n\(manualCommand)"
        case let .libraryNotProduced(path):
            return "The DS4 engine build finished but did not produce \(path)."
        case let .libraryLoadFailed(path, reason):
            return "The DS4 engine library \(path) cannot be loaded: \(reason)"
        case let .abiSymbolMissing(path):
            return "The DS4 engine library \(path) does not export zencode_ds4_abi_version."
        case let .abiVersionMismatch(path, found, expected):
            return "The DS4 engine library \(path) has ABI version \(found), but this ZenCODE needs version \(expected). Rebuild it."
        }
    }
}

struct DS4EngineBuilder: DS4EngineBuilding {
    private let processRunner: any DS4EngineProcessRunning
    private let verifier: any DS4EngineLibraryVerifying

    init(
        processRunner: any DS4EngineProcessRunning = DS4EngineProcessRunner(),
        verifier: any DS4EngineLibraryVerifying = DS4EngineDynamicLibraryVerifier()
    ) {
        self.processRunner = processRunner
        self.verifier = verifier
    }

    func build(
        _ request: DS4EngineBuildRequest,
        output: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        try Self.validate(request)
        let rootDirectory = try AgentDS4PathGuard.canonicalRootDirectory(request.rootDirectory)
        let outputURL = try DS4EngineLibraryLocator.expectedURL(
            rootDirectory: rootDirectory,
            backend: request.backend,
            supportDirectory: request.supportDirectory
        )

        let shimDirectory = DS4EngineLibraryLocator.shimDirectory(supportDirectory: request.supportDirectory)
        output("==> Writing the DS4 engine sources to \(shimDirectory.path)")
        try Self.extractShimSources(to: shimDirectory)

        let scriptURL = shimDirectory.appendingPathComponent(DS4EngineShimSources.buildScriptFileName)
        let arguments = [scriptURL.path] + Self.scriptArguments(
            for: request,
            rootDirectory: rootDirectory,
            shimDirectory: shimDirectory,
            outputURL: outputURL
        )
        let manualCommand = Self.manualCommand(for: request)

        let exitCode: Int32
        do {
            exitCode = try await processRunner.run(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: arguments,
                output: output
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DS4EngineBuildError.launchFailed(
                reason: error.localizedDescription,
                manualCommand: manualCommand
            )
        }
        guard exitCode == 0 else {
            throw DS4EngineBuildError.buildFailed(exitCode: exitCode, manualCommand: manualCommand)
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw DS4EngineBuildError.libraryNotProduced(path: outputURL.path)
        }

        output("==> Verifying \(outputURL.lastPathComponent) (dlopen + zencode_ds4_abi_version)")
        let version = try verifier.abiVersion(ofLibraryAt: outputURL)
        guard version == DS4EngineABI.expectedVersion else {
            throw DS4EngineBuildError.abiVersionMismatch(
                path: outputURL.path,
                found: version,
                expected: DS4EngineABI.expectedVersion
            )
        }
        output("==> DS4 engine ready: \(outputURL.path)")
        return outputURL
    }

    /// A complete shell command that repeats the build by hand, for error messages.
    /// It needs the sources extracted by a previous `build`, which has always
    /// happened by the time a build error is reported.
    static func manualCommand(for request: DS4EngineBuildRequest) -> String {
        let shimDirectory = DS4EngineLibraryLocator.shimDirectory(supportDirectory: request.supportDirectory)
        let scriptURL = shimDirectory.appendingPathComponent(DS4EngineShimSources.buildScriptFileName)
        let rootDirectory = (try? AgentDS4PathGuard.canonicalRootDirectory(request.rootDirectory))
            ?? request.rootDirectory
        let outputURL = (try? DS4EngineLibraryLocator.expectedURL(
            rootDirectory: rootDirectory,
            backend: request.backend,
            supportDirectory: request.supportDirectory
        )) ?? DS4EngineLibraryLocator.engineDirectory(
            backend: request.backend,
            hash: "<hash>",
            supportDirectory: request.supportDirectory
        ).appendingPathComponent(DS4EngineABI.libraryFileName, isDirectory: false)
        let arguments = scriptArguments(
            for: request,
            rootDirectory: rootDirectory,
            shimDirectory: shimDirectory,
            outputURL: outputURL
        )
        return (["/bin/bash", scriptURL.path] + arguments).map(shellQuoted).joined(separator: " ")
    }

    /// Arguments of `build-ds4-engine.sh` for a request, without the script path.
    static func scriptArguments(
        for request: DS4EngineBuildRequest,
        rootDirectory: String,
        shimDirectory: URL,
        outputURL: URL
    ) -> [String] {
        var arguments = ["--root", rootDirectory, "--backend", request.backend.rawValue]
        switch request.backend {
        case .cuda:
            if let arch = DS4EngineLibraryLocator.effectiveArch(backend: .cuda, arch: request.cudaArch) {
                arguments += ["--cuda-arch", arch]
            }
        case .rocm:
            if let arch = DS4EngineLibraryLocator.effectiveArch(backend: .rocm, arch: request.rocmArch) {
                arguments += ["--rocm-arch", arch]
            }
        case .metal, .cpu:
            break
        }
        arguments += ["--shim", shimDirectory.path, "--output", outputURL.path]
        return arguments
    }

    /// Writes the embedded shim sources and the build script into `directory`
    /// (script 0755, sources 0644). Existing files are replaced atomically.
    static func extractShimSources(to directory: URL) throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DS4EngineBuildError.shimExtractionFailed(path: directory.path, reason: error.localizedDescription)
        }
        for file in DS4EngineShimSources.files {
            let url = directory.appendingPathComponent(file.name, isDirectory: false)
            do {
                try Data(file.contents.utf8).write(to: url, options: .atomic)
                let isScript = file.name == DS4EngineShimSources.buildScriptFileName
                try fileManager.setAttributes(
                    [.posixPermissions: isScript ? 0o755 : 0o644],
                    ofItemAtPath: url.path
                )
            } catch {
                throw DS4EngineBuildError.shimExtractionFailed(path: url.path, reason: error.localizedDescription)
            }
        }
    }

    // MARK: Private

    private static func validate(_ request: DS4EngineBuildRequest) throws {
        // The architecture is checked first: it ends up on a command line.
        let archToValidate: String?
        switch request.backend {
        case .cuda: archToValidate = request.cudaArch
        case .rocm: archToValidate = request.rocmArch
        case .metal, .cpu: archToValidate = nil
        }
        if let arch = archToValidate?.trimmingCharacters(in: .whitespacesAndNewlines),
           !arch.isEmpty,
           !isValidArch(arch)
        {
            throw DS4EngineBuildError.invalidArchitecture(arch)
        }

        #if os(macOS)
        let supported: Set<AgentDS4RuntimeBackend> = [.metal, .cpu]
        #else
        let supported: Set<AgentDS4RuntimeBackend> = [.cuda, .rocm, .cpu]
        #endif
        guard supported.contains(request.backend) else {
            throw DS4EngineBuildError.unsupportedPlatform(backend: request.backend)
        }
    }

    private static func isValidArch(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar) || "_.+:-".unicodeScalars.contains(scalar)
            )
        }
    }

    /// Single-quotes `value` for a POSIX shell unless it only has safe characters.
    static func shellQuoted(_ value: String) -> String {
        let safe = value.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                CharacterSet.alphanumerics.contains(scalar) || "_@%+=:,./-".unicodeScalars.contains(scalar)
            )
        }
        if !value.isEmpty, safe {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
