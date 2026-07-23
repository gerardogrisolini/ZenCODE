//
//  ZenCODEMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore
import ZenCODESetup

@main
struct ZenCODEMain {
    static func main() async {
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments)

        let didRequestSetup = ZenCODESetupMenuRunner.shouldRun(arguments: arguments)
        if didRequestSetup {
            do {
                try await ZenCODESetupRunner.run()
            } catch {
                AgentOutput.standardError.writeString(
                    "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
                )
                Foundation.exit(1)
            }
            return
        }

        if arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            AgentOutput.standardOutput.writeString(ZenCODEStandaloneHelp.text)
            return
        }

        if ZenCODEDoctorRunner.shouldRun(arguments: arguments) {
            // Non-interactive diagnostics: print a redacted report and exit.
            // Never start setup and never mutate configuration.
            let exitCode = ZenCODEDoctorRunner.run()
            Foundation.exit(exitCode)
        }

        if let option = ZenCODESetupMenuRunner.movedSetupOption(in: arguments) {
            AgentOutput.standardError.writeString(
                "ZenCODE: \(ZenCODESetupMenuError.setupActionMovedToSetup(option).localizedDescription)\n"
            )
            Foundation.exit(1)
        }

        if ZenInspector.status().requiresSetup || requiresRemoteModelSetup() {
            do {
                try await ZenCODESetupRunner.run()
            } catch {
                AgentOutput.standardError.writeString(
                    "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
                )
                Foundation.exit(1)
            }
        }

        await ZenCODECommandLineRunner.main(arguments: arguments)
    }

    private static func requiresRemoteModelSetup() -> Bool {
        guard let manifest = try? AgentSettingsManifestStore.loadRequired(
            from: AgentSettingsManifestStore.settingsURL()
        ) else {
            return false
        }
        return manifest.models.isEmpty
    }
}

private enum ZenCODEStandaloneHelp {
    static var text: String {
        let usage = "zen [--setup] [--doctor] [--acp]"
        let setupDetail = "remote providers, models, agents"
        let options = """
          --acp                  ACP JSON-RPC over stdio for compatible clients.
          --setup                Open setup for \(setupDetail).
          --doctor               Print a redacted diagnostic report (environment, configuration, permissions) and exit. Non-interactive; never starts setup or reveals secrets.
        """

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
