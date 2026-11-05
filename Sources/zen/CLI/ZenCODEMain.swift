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
            // `--install-features` is a textual meta-command. Ignore `--jsonl`
            // before handing arguments to its own strict parser so output and
            // exit semantics are exactly the same as the ordinary invocation.
            let installerArguments = arguments.filter { $0 != "--jsonl" }
            Foundation.exit(await ZenCODEOptionalFeatureInstaller.run(arguments: installerArguments))
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

        #if os(macOS)
        if ZenAppLaunchCommand.isRequested(arguments) {
            // `zen --ui` opens the macOS app and exits. It accepts only the
            // options the app reads, so its own parser runs instead of
            // `validateArguments`; then the key migration and the setup gate
            // run exactly as for the chat, since the app has no setup.
            let forwardedArguments: [String]
            do {
                forwardedArguments = try ZenAppLaunchCommand.forwardedArguments(from: arguments)
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            AgentProviderKeyMigration.migrateIfNeededReportingFailures()
            if requiresInteractiveSetup() {
                await completeInteractiveSetupOrExit()
            }
            Foundation.exit(await ZenAppLaunchCommand.run(forwardedArguments: forwardedArguments))
        }
        #endif

        do {
            try AgentConfiguration.validateArguments(arguments)
        } catch {
            if runsJSONL(arguments) {
                writeJSONLError(error)
            } else {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
            }
            Foundation.exit(1)
        }

        // Settings v15 identify providers by stable keys. Migrate older
        // settings.json/agents.json pairs here, once, before the setup gate
        // and every mode (TUI, Telegram, headless, JSONL, ACP) load or save them. The
        // meta-commands above stay read-only. A failure is reported and the
        // legacy files keep loading; the migration is retried at next start.
        AgentProviderKeyMigration.migrateIfNeededReportingFailures()

        // ACP is exempt too: `--acp` must answer `initialize` even without a
        // configuration, so the client can offer the terminal setup method. The
        // setup then runs in its own terminal, never inside the ACP stream.
        // So is `--telegram`: the session has no terminal to run a setup in, and
        // without a configuration it fails in the runner with the ordinary error.
        if requiresInteractiveSetup(), !runsHeadless(arguments), !runsACP(arguments), !runsTelegram(arguments) {
            await completeInteractiveSetupOrExit()
        }

        await ZenCODECommandLineRunner.main(
            arguments: arguments,
            setupHandler: {
                try await runInteractiveSetup()
            },
            backendFactory: ChatSessionRuntimeFactory.productionBackendFactory
        )
    }

    private static func runsJSONL(_ arguments: [String]) -> Bool {
        ZenCODECommandLineRunner.jsonlIsActive(arguments: arguments)
    }

    private static func writeJSONLError(_ error: Error) {
        ZenCODEHeadlessJSONLProtocol.writeFramedError(error)
    }

    private static func runsHeadless(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(where: { $0 == "-p" || $0 == "-f" || $0 == "--prompt" || $0 == "--jsonl" })
            || ProcessInfo.processInfo.environment["ZENCODE_AGENT_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == AgentRunMode.headless.rawValue
    }

    private static func runsACP(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--acp")
            || ProcessInfo.processInfo.environment["ZENCODE_AGENT_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == AgentRunMode.acp.rawValue
    }

    private static func runsTelegram(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains("--telegram")
            || ProcessInfo.processInfo.environment["ZENCODE_AGENT_MODE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == AgentRunMode.telegram.rawValue
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

    /// The setup gate of the chat and of `zen --ui`: runs the interactive
    /// setup and returns once ZenCODE is configured. Exits 0 when the setup
    /// ends without a valid configuration (cancelled), and exits 1 with the
    /// error and the troubleshooting hint when it fails.
    private static func completeInteractiveSetupOrExit() async {
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
            case .dataReplaced:
                // The imported backup replaced the support directory. Its
                // configuration must be validated from scratch, so offer
                // setup again exactly like after a reset.
                continue
            }
        }
    }
}

private enum ZenCODEStandaloneHelp {
    static var text: String {
        let usage = "zen [--doctor] [--install-features [id,id,...]] [--tui] [--telegram] [--jsonl] [-p PROMPT] [-f PATH] [--acp]"
        let telegramOption = "  --telegram             Run the session from the linked Telegram chat, without the TUI (Telegram must be set up and paired with /setup)."
        // The `--telegram` line follows `--acp` and carries its own indentation,
        // hence the interpolation at the margin of the literal.
        let options = """
          -p, --prompt PROMPT    Run one headless text prompt.
          -f PATH                Run one headless prompt read from a file (absolute path). With -p, the file is added as context.
          --jsonl                Emit headless events and the result as JSON Lines (use with -p/--prompt or -f).
          --acp                  ACP JSON-RPC over stdio for compatible clients.
        \(telegramOption)
          --doctor               Print a redacted diagnostic report (environment, configuration, permissions) and exit. Non-interactive; never starts setup or reveals secrets.
          --install-features [id,id,...]
                                 Select and install optional Swift feature packages. Repeat the option or separate ids with commas for a non-interactive install.
          --no-features          With --install-features, skip optional feature installation.
          --zen-package-path DIR Source ZenCODE checkout used to install optional features.
        """

        let help = AgentConfiguration.helpText
            .replacingOccurrences(
                of: "zen [--tui] [--telegram] [-p PROMPT] [-f PATH] [--jsonl] [--acp]",
                with: usage
            )
            .replacingOccurrences(
                of: "  -p, --prompt PROMPT    Run one headless text prompt.\n  -f PATH                Run one headless prompt read from a file (absolute path). With -p, the file is added as context.\n  --jsonl                Emit headless events and the result as JSON Lines (use with -p/--prompt or -f).\n  --acp                  ACP JSON-RPC over stdio for compatible clients.\n\(telegramOption)",
                with: options
            )

        #if os(macOS)
        // `--ui` exists only on macOS: elsewhere the help stays as above.
        let uiOption = "  --ui                   Open the ZenCODE macOS app (built on first use). Accepts --agent, --model, --skills, --working-directory."
        return help
            .replacingOccurrences(of: usage, with: "\(usage) [--ui]")
            .replacingOccurrences(of: telegramOption, with: "\(telegramOption)\n\(uiOption)")
        #else
        return help
        #endif
    }
}
