//
//  ZenCODESetupMenuRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import ZenCODESetup
#if ZENCODE_LOCAL_MLX
import MLXServerSetup
#endif

enum ZenCODESetupMenuRunner {
    static let option = "--setup"

    static func shouldRun(arguments: [String]) -> Bool {
        arguments.dropFirst().contains(option)
    }

    static func movedSetupOption(
        in arguments: [String],
        mlxMode: Bool
    ) -> String? {
        let movedOptions: [String]
        if mlxMode {
            #if ZENCODE_LOCAL_MLX
            movedOptions = ["--setup", "--setup-models", "--reset", "--reset-disk-cache"]
            #else
            movedOptions = []
            #endif
        } else {
            movedOptions = ["--setup-agents", "--reset"]
        }
        return arguments.dropFirst().first { movedOptions.contains($0) }
    }

    static func quickActions() -> [ZenCODESetupQuickAction] {
        #if ZENCODE_LOCAL_MLX
        return [
            ZenCODESetupQuickAction(
                title: "local MLX inference",
                detail: "runtime defaults and suggested model download"
            ) {
                _ = try MLXServerSetupRunner.runQuickSetup()
                let result = try await MLXServerModelSetupRunner.runQuickSetup()
                let usageHint: String
                if result.hasUsableModel {
                    usageHint = "Local MLX is ready. Start it with: zen --mlx"
                } else {
                    usageHint = "Local MLX settings are configured. Add a local model from zen --setup, then start with: zen --mlx"
                }
                return .configuredStandaloneRuntime(
                    usageHint: usageHint,
                    hasUsableModel: result.hasUsableModel
                )
            }
        ]
        #else
        return []
        #endif
    }

    static func additionalSectionGroups() -> [ZenCODESetupAdditionalSectionGroup] {
        var groups: [ZenCODESetupAdditionalSectionGroup] = []
        var localInferenceSections: [ZenCODESetupAdditionalSection] = []
        var localInferenceSectionTitles: [String] = []

        #if ZENCODE_LOCAL_MLX
        localInferenceSections += [
            ZenCODESetupAdditionalSection(
                title: "MLX runtime",
                detail: "settings and cache policy",
                aliases: ["mlx", "mlx setup", "local mlx", "runtime"]
            ) {
                try MLXServerSetupRunner.run(arguments: [])
                return .unchanged
            },
            ZenCODESetupAdditionalSection(
                title: "MLX models",
                detail: "catalog and downloads",
                aliases: ["mlx models", "models setup"]
            ) {
                try await MLXServerModelSetupRunner.run(arguments: [])
                return .unchanged
            }
        ]
        localInferenceSectionTitles += ["MLX runtime", "MLX models"]
        #endif

        #if ZENCODE_LOCAL_DS4
        localInferenceSections.append(ds4RuntimeSetupSection())
        localInferenceSections.append(ds4ModelsSetupSection())
        localInferenceSectionTitles += ["DS4 runtime", "DS4 models"]
        #endif

        if !localInferenceSections.isEmpty {
            groups.append(
                ZenCODESetupAdditionalSectionGroup(
                    title: "Local inference",
                    detail: localInferenceSectionTitles.joined(separator: ", "),
                    aliases: ["local inference", "local", "mlx", "ds4", "runtime"],
                    placement: .afterAgents,
                    sections: localInferenceSections
                )
            )
        }

        var resetSections: [ZenCODESetupAdditionalSection] = [
            ZenCODESetupAdditionalSection(
                title: "Reset ZenCODE configuration",
                detail: "remove standalone support files",
                aliases: ["reset ZenCODE", "reset configuration"]
            ) {
                try ZenCODEResetConfigurationCommand.run()
                return .removedStandaloneConfiguration
            }
        ]

        #if ZENCODE_LOCAL_MLX
        resetSections += [
            ZenCODESetupAdditionalSection(
                title: "Reset local MLX configuration",
                detail: "remove local runtime settings",
                aliases: ["mlx reset", "local mlx reset"]
            ) {
                try ZenCODEMLXResetConfigurationCommand.run()
                return .unchanged
            },
            ZenCODESetupAdditionalSection(
                title: "Reset local MLX disk cache",
                detail: "clear persisted local KV cache",
                aliases: ["disk cache", "reset disk cache", "kv cache", "cache"]
            ) {
                try ZenCODEMLXResetDiskCacheCommand.run()
                return .unchanged
            }
        ]
        #endif

        groups.append(
            ZenCODESetupAdditionalSectionGroup(
                title: "Reset",
                detail: "configuration and cache",
                aliases: ["reset", "resets"],
                placement: .afterVoice,
                prefersBackDefault: true,
                sections: resetSections
            )
        )

        return groups
    }
}

enum ZenCODESetupMenuError: LocalizedError {
    case setupActionMovedToSetup(String)

    var errorDescription: String? {
        switch self {
        case .setupActionMovedToSetup(let option):
            return "\(option) is now available from zen --setup."
        }
    }
}
