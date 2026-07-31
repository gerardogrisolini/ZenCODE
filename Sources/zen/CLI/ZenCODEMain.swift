//
//  ZenCODEMain.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenCODECore
import ZenPackageMetadata

@main
struct ZenCODEMain {
    static func main() async {
        let arguments = ZenCODECommandLineArgumentSanitizer.sanitized(CommandLine.arguments)

        // This must run before the configuration gate. Optional features are
        // useful on a fresh installation, where no provider or model exists yet.
        if ZenCODEOptionalFeatureInstaller.shouldRun(arguments: arguments) {
            Foundation.exit(await ZenCODEOptionalFeatureInstaller.run(arguments: arguments))
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

        do {
            try AgentConfiguration.validateArguments(arguments)
        } catch {
            AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }

        if requiresInteractiveSetup() {
            do {
                guard try await runInteractiveSetup() else {
                    Foundation.exit(0)
                }
            } catch {
                AgentOutput.standardError.writeString(
                    "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
                )
                Foundation.exit(1)
            }
        }

        await ZenCODECommandLineRunner.main(
            arguments: arguments,
            setupHandler: {
                try await runInteractiveSetup()
            }
        )
    }

    private static func requiresInteractiveSetup() -> Bool {
        let manifest = try? AgentSettingsManifestStore.loadRequired(
            from: AgentSettingsManifestStore.settingsURL()
        )
        return ZenCODESetupRequirement.isRequired(
            manifest: manifest,
            status: ZenInspector.status()
        )
    }

    private static func runInteractiveSetup() async throws -> Bool {
        while true {
            let outcome = try await ZenCODESetupRunner.run()
            switch outcome {
            case .configured:
                return !requiresInteractiveSetup()
            case .cancelled:
                return !requiresInteractiveSetup()
            case .reset:
                // Reset deliberately removes the active configuration. Stay in
                // the same process and immediately offer setup again; if the next
                // run is cancelled, the validity check above ends the app cleanly.
                continue
            }
        }
    }
}

private enum ZenCODEStandaloneHelp {
    static var text: String {
        let usage = "zen [--doctor] [--install-features [id,id,...]] [--acp]"
        let options = """
          --acp                  ACP JSON-RPC over stdio for compatible clients.
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
