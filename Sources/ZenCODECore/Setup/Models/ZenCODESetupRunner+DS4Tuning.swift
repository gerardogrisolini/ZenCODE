//
//  ZenCODESetupRunner+DS4Tuning.swift
//  ZenCODE
//
//  Per-model DS4 launch options asked by the setup, in sequence. Every prompt
//  starts from the value saved for that model.
//

import Foundation
import ZenCODERuntime

extension ZenCODESetupRunner {
    /// Asks the launch options of one model that setup still asks: the
    /// context window, SSD streaming, MTP and, for the CUDA and ROCm backends,
    /// the architecture of the engine build. The default shown is the saved
    /// value.
    ///
    /// MTP is the speculative decoding built into the GLM and Qwen GGUFs, so
    /// it is not asked for a DeepSeek model (`usesDSpark`), which uses DSpark
    /// instead (chosen with its support model) and gets MTP off.
    ///
    /// Every other value of the tuning (power, quality, warm weights, threads,
    /// prefill chunk, MTP draft and margin, steering, engine sessions, extra
    /// engine arguments) is returned as it is in `defaults`: setup no longer
    /// asks it, and a model keeps the value it has.
    static func promptDS4RuntimeTuning(
        modelTitle: String,
        defaults: AgentDS4RuntimeTuning,
        backend: AgentDS4RuntimeBackend = .metal,
        usesDSpark: Bool = false
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
            help: usesDSpark
                ? "Streams experts from SSD instead of keeping all experts resident. DeepSeek V4 Flash DSpark needs the model resident; V4.1 supports both."
                : "Streams experts from SSD instead of keeping all experts resident."
        )
        var mtp = false
        if !usesDSpark {
            mtp = try promptYesNo(
                "\(prefix)Enable MTP speculative decoding (--mtp)?",
                defaultValue: defaults.mtp,
                help: "Uses the multi-token prediction block built into the GLM and Qwen GGUFs; no extra file is needed. Gains depend on the workload."
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

        return AgentDS4RuntimeTuning(
            contextWindow: contextWindow,
            ssdStreaming: ssdStreaming,
            mtp: mtp,
            power: defaults.power,
            dspark: defaults.dspark,
            mtpDraftTokens: defaults.mtpDraftTokens,
            mtpMargin: defaults.mtpMargin,
            quality: defaults.quality,
            threads: defaults.threads,
            prefillChunk: defaults.prefillChunk,
            warmWeights: defaults.warmWeights,
            steeringRelativePath: defaults.steeringRelativePath,
            steeringFFN: defaults.steeringFFN,
            steeringAttn: defaults.steeringAttn,
            cudaArch: cudaArch,
            rocmArch: rocmArch,
            engineSessions: defaults.engineSessions,
            extraEngineArguments: defaults.extraEngineArguments
        )
    }

    // MARK: Prompt helpers

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
}
