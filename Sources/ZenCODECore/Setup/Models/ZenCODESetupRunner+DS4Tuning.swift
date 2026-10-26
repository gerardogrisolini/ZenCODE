//
//  ZenCODESetupRunner+DS4Tuning.swift
//  ZenCODE
//
//  Per-model DS4 launch options asked by the setup, in sequence. Every prompt
//  starts from the value saved for that model.
//

import Foundation

extension ZenCODESetupRunner {
    /// Asks the launch options of one model. Optional values are answered with
    /// `none` (the engine default); the default shown is the saved value.
    ///
    /// Some questions only make sense in context and are skipped (the saved
    /// value is kept): MTP draft tokens and margin need an MTP file, DSpark or
    /// MTP; the steering scales need a steering file; the architecture needs
    /// the CUDA or ROCm backend.
    static func promptDS4RuntimeTuning(
        modelTitle: String,
        defaults: AgentDS4RuntimeTuning,
        backend: AgentDS4RuntimeBackend = .metal,
        rootDirectory: String? = nil,
        hasMTPModel: Bool = false
    ) throws -> AgentDS4RuntimeTuning {
        let prefix = "\(modelTitle) · "

        let contextWindow = try promptDS4Integer(
            "\(prefix)DS4 context window (--ctx)",
            defaultValue: defaults.contextWindow,
            range: 1...1_048_576,
            help: "Enter the DS4 context window in tokens (1...1048576)."
        )
        let ssdStreaming = try promptYesNo(
            "\(prefix)Enable DS4 SSD streaming (--ssd-streaming)?",
            defaultValue: defaults.ssdStreaming,
            help: "Streams experts from SSD instead of keeping all experts resident."
        )
        let mtp = try promptYesNo(
            "\(prefix)Enable DS4 MTP (--mtp)?",
            defaultValue: defaults.mtp,
            help: "Turns on the internal GLM multi-token prediction. The MTP / DSpark support model is chosen separately."
        )
        let power = try promptDS4Integer(
            "\(prefix)DS4 power (--power)",
            defaultValue: defaults.power,
            range: 1...100,
            help: "Enter the DS4 power value (1...100; upstream default is 100)."
        )
        let quality = try promptYesNo(
            "\(prefix)Enable DS4 quality mode (--quality)?",
            defaultValue: defaults.quality,
            help: "Prefers exactness over speed in the engine."
        )
        let warmWeights = try promptYesNo(
            "\(prefix)Warm the DS4 weights at startup (--warm-weights)?",
            defaultValue: defaults.warmWeights,
            help: "Touches the weights when the engine opens so the first request does not pay for the page faults."
        )
        let threads = try promptDS4OptionalInteger(
            "\(prefix)DS4 CPU threads (-t)",
            defaultValue: defaults.threads,
            range: 1...Int(Int32.max),
            help: "Enter a thread count, or none to let DS4 decide."
        )
        let prefillChunk = try promptDS4OptionalInteger(
            "\(prefix)DS4 prefill chunk (--prefill-chunk)",
            defaultValue: defaults.prefillChunk,
            range: 1...Int(Int32.max),
            help: "Enter the prompt prefill chunk in tokens, or none for the DS4 default."
        )

        let dspark = try promptYesNo(
            "\(prefix)Enable DSpark speculative decoding (--dspark)?",
            defaultValue: defaults.dspark,
            help: "Uses the MTP / DSpark support model, when one is paired with this model."
        )
        var mtpDraftTokens = defaults.mtpDraftTokens
        var mtpMargin = defaults.mtpMargin
        if hasMTPModel || dspark || mtp {
            mtpDraftTokens = try promptDS4OptionalInteger(
                "\(prefix)DS4 MTP draft tokens (--mtp-draft)",
                defaultValue: defaults.mtpDraftTokens,
                range: AgentDS4RuntimeManifest.mtpDraftTokensRange,
                help: "Enter 1...16 draft tokens per step, or none for the DS4 default (1)."
            )
            mtpMargin = try promptDS4OptionalDouble(
                "\(prefix)DS4 MTP margin (--mtp-margin)",
                defaultValue: defaults.mtpMargin,
                range: AgentDS4RuntimeManifest.mtpMarginRange,
                help: "Enter a margin between 0 and 1000, or none for the DS4 default (3.0)."
            )
        }

        let steeringRelativePath = try promptDS4SteeringFile(
            "\(prefix)DS4 directional steering file (--dir-steering-file)",
            defaultValue: defaults.steeringRelativePath,
            rootDirectory: rootDirectory
        )
        var steeringFFN = defaults.steeringFFN
        var steeringAttn = defaults.steeringAttn
        if steeringRelativePath != nil {
            steeringFFN = try promptDS4OptionalDouble(
                "\(prefix)DS4 FFN steering scale (--dir-steering-ffn)",
                defaultValue: defaults.steeringFFN,
                range: AgentDS4RuntimeManifest.steeringScaleRange,
                help: "Enter a scale between -100 and 100, or none for the DS4 default (1 when a file is set)."
            )
            steeringAttn = try promptDS4OptionalDouble(
                "\(prefix)DS4 attention steering scale (--dir-steering-attn)",
                defaultValue: defaults.steeringAttn,
                range: AgentDS4RuntimeManifest.steeringScaleRange,
                help: "Enter a scale between -100 and 100, or none for the DS4 default (0)."
            )
        }

        var cudaArch = defaults.cudaArch
        var rocmArch = defaults.rocmArch
        switch backend {
        case .cuda:
            cudaArch = try promptDS4Architecture(
                "\(prefix)CUDA architecture for the engine build",
                defaultValue: defaults.cudaArch,
                fallback: DS4EngineLibraryLocator.defaultCUDAArch,
                option: "cudaArch",
                help: "For example sm_120, or native for the installed GPU."
            )
        case .rocm:
            rocmArch = try promptDS4Architecture(
                "\(prefix)ROCm architecture for the engine build",
                defaultValue: defaults.rocmArch,
                fallback: DS4EngineLibraryLocator.defaultROCmArch,
                option: "rocmArch",
                help: "For example gfx1151 or gfx1100."
            )
        case .metal, .cpu:
            break
        }

        let engineSessions = try promptDS4Integer(
            "\(prefix)DS4 engine sessions",
            defaultValue: defaults.engineSessions,
            range: AgentDS4RuntimeManifest.engineSessionsRange,
            help: "Number of conversations the engine keeps open at once (1...8; default 2)."
        )
        let extraEngineArguments = try promptDS4EngineArguments(
            "\(prefix)Extra DS4 engine arguments (advanced)",
            defaultValue: defaults.extraEngineArguments
        )

        return AgentDS4RuntimeTuning(
            contextWindow: contextWindow,
            ssdStreaming: ssdStreaming,
            mtp: mtp,
            power: power,
            dspark: dspark,
            mtpDraftTokens: mtpDraftTokens,
            mtpMargin: mtpMargin,
            quality: quality,
            threads: threads,
            prefillChunk: prefillChunk,
            warmWeights: warmWeights,
            steeringRelativePath: steeringRelativePath,
            steeringFFN: steeringFFN,
            steeringAttn: steeringAttn,
            cudaArch: cudaArch,
            rocmArch: rocmArch,
            engineSessions: engineSessions,
            extraEngineArguments: extraEngineArguments
        )
    }

    // MARK: Prompt helpers

    /// Answers that mean "no value: use the engine default".
    private static func isDS4UnsetAnswer(_ value: String) -> Bool {
        ["none", "auto", "default", "-"].contains(value.lowercased())
    }

    static func promptDS4Integer(
        _ label: String,
        defaultValue: Int,
        range: ClosedRange<Int>,
        help: String
    ) throws -> Int {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: String(defaultValue),
                allowEmpty: false,
                help: help
            )
            guard let value = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  range.contains(value) else {
                AgentOutput.standardError.writeString(
                    "\(label) must be between \(range.lowerBound) and \(range.upperBound). Enter ? for help.\n"
                )
                continue
            }
            return value
        }
    }

    private static func promptDS4OptionalInteger(
        _ label: String,
        defaultValue: Int?,
        range: ClosedRange<Int>,
        help: String
    ) throws -> Int? {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: defaultValue.map(String.init) ?? "none",
                allowEmpty: false,
                help: help
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if isDS4UnsetAnswer(rawValue) {
                return nil
            }
            guard let value = Int(rawValue), range.contains(value) else {
                AgentOutput.standardError.writeString(
                    "\(label) must be none or between \(range.lowerBound) and \(range.upperBound). Enter ? for help.\n"
                )
                continue
            }
            return value
        }
    }

    private static func promptDS4OptionalDouble(
        _ label: String,
        defaultValue: Double?,
        range: ClosedRange<Double>,
        help: String
    ) throws -> Double? {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: defaultValue.map { String($0) } ?? "none",
                allowEmpty: false,
                help: help
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if isDS4UnsetAnswer(rawValue) {
                return nil
            }
            guard let value = Double(rawValue), value.isFinite, range.contains(value) else {
                AgentOutput.standardError.writeString(
                    "\(label) must be none or between \(range.lowerBound) and \(range.upperBound). Enter ? for help.\n"
                )
                continue
            }
            return value
        }
    }

    /// Steering file under the DS4 folder (`none` for no steering). The file has
    /// to exist, as the engine opens it.
    private static func promptDS4SteeringFile(
        _ label: String,
        defaultValue: String?,
        rootDirectory: String?
    ) throws -> String? {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: defaultValue ?? "none",
                allowEmpty: false,
                help: "Path of a steering direction file relative to the DS4 folder (for example dir-steering/out/verbosity.f32), or none."
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if isDS4UnsetAnswer(rawValue) {
                return nil
            }
            do {
                let normalized = try AgentDS4PathGuard.normalizedModelRelativePath(rawValue)
                if let rootDirectory {
                    _ = try AgentDS4PathGuard.resolveModelURL(
                        rootDirectory: rootDirectory,
                        modelRelativePath: normalized
                    )
                }
                return normalized
            } catch {
                AgentOutput.standardError.writeString("\(error.localizedDescription)\n")
            }
        }
    }

    /// CUDA / ROCm architecture. The backend default is stored as `nil`.
    private static func promptDS4Architecture(
        _ label: String,
        defaultValue: String?,
        fallback: String,
        option: String,
        help: String
    ) throws -> String? {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: defaultValue ?? fallback,
                allowEmpty: false,
                help: help
            )
            do {
                let architecture = try AgentDS4RuntimeManifest.normalizedArchitecture(rawValue, option: option)
                return architecture == fallback ? nil : architecture
            } catch {
                AgentOutput.standardError.writeString("\(error.localizedDescription)\n")
            }
        }
    }

    /// Opaque `extra_arg` tokens, split on whitespace (`none` for no arguments).
    private static func promptDS4EngineArguments(
        _ label: String,
        defaultValue: [String]
    ) throws -> [String] {
        while true {
            let rawValue = try promptString(
                label,
                defaultValue: defaultValue.isEmpty ? "none" : defaultValue.joined(separator: " "),
                allowEmpty: false,
                help: "Advanced: extra engine arguments for distributed, tensor-parallel or multi-GPU runs (for example --gpu-devices 0,1), separated by spaces, or none. The engine validates them when it opens."
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if rawValue.lowercased() == "none" {
                return []
            }
            let tokens = rawValue.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let invalid = tokens.first(where: { !AgentDS4RuntimeManifest.isValidEngineArgument($0) }) else {
                return tokens
            }
            AgentOutput.standardError.writeString(
                "\(AgentDS4RuntimeConfigurationError.invalidEngineArgument(invalid).localizedDescription)\n"
            )
        }
    }
}
