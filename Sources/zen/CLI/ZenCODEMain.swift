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
            // have no ~/.zencode configuration, so the gate below would stop
            // the run instead of printing the version.
            AgentOutput.standardOutput.writeString("ZenCODE \(ZenPackageMetadata.version)\n")
            return
        }

        if ZenCODEDoctorRunner.shouldRun(arguments: arguments) {
            // Non-interactive diagnostics: print a redacted report and exit.
            // Never start setup and never mutate configuration.
            let exitCode = ZenCODEDoctorRunner.run()
            Foundation.exit(exitCode)
        }

        if ZenCODESetupCommand.shouldRun(arguments: arguments) {
            // `zen --setup` is the only way into the interactive setup. It
            // accepts no other option, so its errors stay textual even with
            // `--jsonl`, and it never enters the chat.
            await runSetupCommandAndExit(arguments: arguments)
        }

        #if os(macOS)
        if ZenAppLaunchCommand.isRequested(arguments) {
            // `zen --ui` opens the macOS app and exits. It accepts only the
            // options the app reads, so its own parser runs instead of
            // `validateArguments`; then the key migration and the setup gate
            // run as for the chat: without a configuration the app is not
            // opened, and the message points to `zen --setup`.
            let forwardedArguments: [String]
            do {
                forwardedArguments = try ZenAppLaunchCommand.forwardedArguments(from: arguments)
            } catch {
                AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
                Foundation.exit(1)
            }
            AgentProviderKeyMigration.migrateIfNeededReportingFailures()
            if ZenCODESetupRequirement.isRequired() {
                exitNotConfigured(jsonl: false)
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

        // The setup gate: without a usable configuration every mode stops and
        // points to `zen --setup`. ACP alone is exempt: it must answer
        // `initialize` even without a configuration, so the client can offer
        // the terminal setup method, which launches `zen --setup` in its own
        // terminal, never inside the ACP stream.
        if ZenCODESetupRequirement.gateApplies(arguments: arguments),
           ZenCODESetupRequirement.isRequired() {
            exitNotConfigured(jsonl: runsJSONL(arguments))
        }

        await ZenCODECommandLineRunner.main(
            arguments: arguments,
            backendFactory: ChatSessionRuntimeFactory.productionBackendFactory
        )
    }

    private static func runsJSONL(_ arguments: [String]) -> Bool {
        ZenCODECommandLineRunner.jsonlIsActive(arguments: arguments)
    }

    private static func writeJSONLError(_ error: Error) {
        ZenCODEHeadlessJSONLProtocol.writeFramedError(error)
    }

    /// `zen --setup`: validates that no other option is given, migrates the
    /// settings like every mode, and runs the interactive setup until it ends.
    /// Exits 0 when ZenCODE is configured at the end and 1 when it is not (the
    /// setup was cancelled before a usable configuration existed); an error
    /// prints the troubleshooting hint too and exits 1.
    private static func runSetupCommandAndExit(arguments: [String]) async -> Never {
        do {
            try ZenCODESetupCommand.validateArguments(arguments)
        } catch {
            AgentOutput.standardError.writeString("ZenCODE: \(error.localizedDescription)\n")
            Foundation.exit(1)
        }
        AgentProviderKeyMigration.migrateIfNeededReportingFailures()
        do {
            Foundation.exit(try await ZenCODESetupCommand.run() ? 0 : 1)
        } catch {
            AgentOutput.standardError.writeString(
                "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
            )
            Foundation.exit(1)
        }
    }

    /// Stops a run that the setup gate refused: the not-configured message on
    /// standard error (without the `ZenCODE: ` prefix), or its framed error
    /// record on standard output when `--jsonl` owns it; then exits 1.
    private static func exitNotConfigured(jsonl: Bool) -> Never {
        if jsonl {
            ZenCODEHeadlessJSONLProtocol.writeFramedError(ZenCODESetupRequirement.NotConfiguredError())
        } else {
            AgentOutput.standardError.writeString("\(ZenCODESetupRequirement.notConfiguredMessage)\n")
        }
        Foundation.exit(1)
    }
}

private enum ZenCODEStandaloneHelp {
    static var text: String {
        let usage = "zen [--doctor] [--setup] [--install-features [id,id,...]] [--tui] [--telegram] [--jsonl] [-p PROMPT] [-f PATH] [--acp]"
        let telegramOption = "  --telegram             Run the session from the linked Telegram chat, without the TUI (Telegram must be set up and paired with zen --setup)."
        let setupOption = "  --setup                Open the interactive setup and exit. Requires an interactive terminal; cannot be combined with other options."
        // The `--telegram` and `--setup` lines carry their own indentation,
        // hence the interpolations at the margin of the literal. `--setup`
        // moves from after `--telegram` to after `--doctor`.
        let options = """
          -p, --prompt PROMPT    Run one headless text prompt.
          -f PATH                Run one headless prompt read from a file (absolute path). With -p, the file is added as context.
          --jsonl                Emit headless events and the result as JSON Lines (use with -p/--prompt or -f).
          --acp                  ACP JSON-RPC over stdio for compatible clients.
        \(telegramOption)
          --doctor               Print a redacted diagnostic report (environment, configuration, permissions) and exit. Non-interactive; never starts setup or reveals secrets.
        \(setupOption)
          --install-features [id,id,...]
                                 Select and install optional Swift feature packages. Repeat the option or separate ids with commas for a non-interactive install.
          --no-features          With --install-features, skip optional feature installation.
          --zen-package-path DIR Source ZenCODE checkout used to install optional features.
        """

        // Both replacements match exactly: keep them in sync with
        // `AgentConfiguration.helpText`, or they silently change nothing.
        let help = AgentConfiguration.helpText
            .replacingOccurrences(
                of: "zen [--setup] [--tui] [--telegram] [-p PROMPT] [-f PATH] [--jsonl] [--acp]",
                with: usage
            )
            .replacingOccurrences(
                of: "  -p, --prompt PROMPT    Run one headless text prompt.\n  -f PATH                Run one headless prompt read from a file (absolute path). With -p, the file is added as context.\n  --jsonl                Emit headless events and the result as JSON Lines (use with -p/--prompt or -f).\n  --acp                  ACP JSON-RPC over stdio for compatible clients.\n\(telegramOption)\n\(setupOption)",
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
