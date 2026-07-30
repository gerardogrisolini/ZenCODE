//
//  ZenCODEMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore
import ZenCODESetup
import ZenPackageMetadata

@main
struct ZenCODEMain {
    static func main() async {
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments)

        // This must run before every setup path. Optional features are useful on
        // a fresh installation, where no remote provider or model has been
        // configured yet.
        if ZenCODEOptionalFeatureInstaller.shouldRun(arguments: arguments) {
            Foundation.exit(await ZenCODEOptionalFeatureInstaller.run(arguments: arguments))
        }

        let didRequestSetup = ZenCODESetupMenuRunner.shouldRun(arguments: arguments)
        if didRequestSetup {
            do {
                _ = try await ZenCODESetupRunner.run()
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

        if arguments.dropFirst().contains("--version") {
            // Must short-circuit before the setup gate: CI and fresh installs
            // have no ~/.zencode configuration, so the status check below would
            // launch the interactive setup flow instead of printing the version.
            AgentOutput.standardOutput.writeString("ZenCODE \(ZenPackageMetadata.version)\n")
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
                // Start the interactive runner only when setup produced a usable
                // configuration. A cancellation or a reset leaves the CLI to a
                // later invocation instead of launching the chat half-configured.
                let outcome = try await ZenCODESetupRunner.run()
                guard outcome == .configured else {
                    Foundation.exit(0)
                }
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
        let usage = "zen [--setup] [--doctor] [--install-features [id,id,...]] [--acp]"
        let setupDetail = "remote providers, models, agents"
        let options = """
          --acp                  ACP JSON-RPC over stdio for compatible clients.
          --setup                Open setup for \(setupDetail).
          --doctor               Print a redacted diagnostic report (environment, configuration, permissions) and exit. Non-interactive; never starts setup or reveals secrets.
          --install-features [id,id,...]
                                 Select and install optional Swift feature packages. Repeat the option or separate ids with commas for a non-interactive install.
          --no-features          With --install-features, skip optional feature installation.
          --zen-package-path DIR Source ZenCODE checkout used to install optional features.
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
