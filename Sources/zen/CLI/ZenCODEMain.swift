//
//  ZenCODEMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore
import ZenCODESetup
#if ZENCODE_LOCAL_MLX
import MLXServerCore
#endif

@main
struct ZenCODEMain {
    static func main() async {
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments)
        if arguments.dropFirst().contains("--mlx"),
           let option = ZenCODESetupMenuRunner.movedSetupOption(
               in: arguments,
               mlxMode: true
           ) {
            AgentOutput.standardError.writeString(
                "ZenCODE: \(ZenCODESetupMenuError.setupActionMovedToSetup(option).localizedDescription)\n"
            )
            Foundation.exit(1)
        }

        let didRequestSetup = ZenCODESetupMenuRunner.shouldRun(arguments: arguments)
        if didRequestSetup {
            do {
                try await ZenCODESetupRunner.run(
                    arguments: [],
                    additionalSectionGroups: ZenCODESetupMenuRunner.additionalSectionGroups(),
                    quickActions: ZenCODESetupMenuRunner.quickActions()
                )
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            return
        }

        let requestedDS4 = arguments.dropFirst().contains("--ds4")
        #if ZENCODE_LOCAL_DS4
        if requestedDS4 {
            do {
                try await ZenCODEDS4Command.run(arguments: arguments)
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            return
        }
        #else
        if requestedDS4 {
            AgentOutput.standardError.writeString(
                "ZenCODE: this build does not include DS4 support. Reinstall with DS4 support enabled.\n"
            )
            Foundation.exit(1)
        }
        #endif

        let requestedMLX = arguments.dropFirst().contains("--mlx")
        #if ZENCODE_LOCAL_MLX
        if requestedMLX {
            do {
                try await ZenCODEMLXCommand.run(arguments: arguments)
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            return
        }
        #else
        if requestedMLX {
            AgentOutput.standardError.writeString(
                "ZenCODE: this build does not include local MLX support. Reinstall with MLX support enabled.\n"
            )
            Foundation.exit(1)
        }
        #endif

        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            AgentOutput.standardOutput.writeString(ZenCODEStandaloneHelp.text)
            return
        }

        if let option = ZenCODESetupMenuRunner.movedSetupOption(
            in: arguments,
            mlxMode: false
        ) {
            AgentOutput.standardError.writeString(
                "ZenCODE: \(ZenCODESetupMenuError.setupActionMovedToSetup(option).localizedDescription)\n"
            )
            Foundation.exit(1)
        }

        if ZenInspector.status().requiresSetup {
            do {
                try await ZenCODESetupRunner.run(
                    arguments: [],
                    additionalSectionGroups: ZenCODESetupMenuRunner.additionalSectionGroups(),
                    quickActions: ZenCODESetupMenuRunner.quickActions()
                )
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
        }

        #if ZENCODE_LOCAL_MLX
        if let guidance = localOnlySetupGuidance() {
            AgentOutput.standardError.writeString(guidance)
            return
        }
        #endif

        await ZenCODECommandLineRunner.main(arguments: arguments)
    }

    #if ZENCODE_LOCAL_MLX
    private static func localOnlySetupGuidance() -> String? {
        guard let manifest = AgentSettingsManifestStore.load(), manifest.models.isEmpty else {
            return nil
        }

        let hasLocalSettings = (try? MLXServerSettingsStore.loadRequired()) != nil
        let localModelCount = (try? MLXServerModelsManifestStore.loadRequired().models.filter(\.enabled).count) ?? 0
        guard hasLocalSettings || localModelCount > 0 else {
            return nil
        }

        if localModelCount > 0 {
            return "ZenCODE is configured for local MLX. Start it with: zen --mlx\n"
        }
        return "Local MLX settings are configured, but no local model is installed yet. Add one from zen --setup, then start with: zen --mlx\n"
    }
    #endif
}

private enum ZenCODEStandaloneHelp {
    static var text: String {
        var usage = "zen [--setup]"
        var setupDetail = "providers, models, agents"
        var options = """
          --acp                  ACP JSON-RPC over stdio for compatible clients.
        """

        #if ZENCODE_LOCAL_MLX
        usage += " [--mlx]"
        setupDetail += ", local MLX"
        options += """

          --mlx                  Use the embedded local MLX runtime. Run zen --setup for setup and reset options.
        """
        #endif

        #if ZENCODE_LOCAL_DS4
        usage += " [--ds4]"
        setupDetail += ", DS4"
        options += """

          --ds4                  Use a local DS4 runtime from --ds4-root/libds4.dylib without ds4-server.
        """
        #endif

        usage += " [--acp]"
        options += "\n  --setup                Open setup for \(setupDetail), and resets."

        return AgentConfiguration.helpText
            .replacingOccurrences(
                of: "zen [--acp]",
                with: usage
            )
            .replacingOccurrences(
                of: "  --acp                  ACP JSON-RPC over stdio for compatible clients.",
                with: options
            )
    }
}
