//
//  ZenCODECommandLineRunner.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

public enum ZenCODECommandLineRunner {
    public static func main() async {
        await main(arguments: CommandLine.arguments)
    }

    public static func main(arguments rawArguments: [String]) async {
        do {
            SwiftPMResourceBundleDirectory.configure()

            let sanitizedArguments = ZenCODECommandLineArgumentSanitizer.sanitized(rawArguments)
            if ZenCODEDoctorRunner.shouldRun(arguments: sanitizedArguments) {
                // Non-interactive diagnostics: print a redacted report and exit.
                // Handled before configuration parsing so it never starts setup
                // or is rejected as an unknown argument.
                Foundation.exit(ZenCODEDoctorRunner.run())
            }
            let configuration = try AgentConfiguration(
                arguments: sanitizedArguments
            )
            if configuration.printHelp {
                AgentOutput.standardOutput.writeString(AgentConfiguration.helpText)
                return
            }
            if configuration.printVersion {
                AgentOutput.standardOutput.writeString("ZenCODE \(agentVersion)\n")
                return
            }

            let interactiveInputAvailable = TerminalRawInput.supportsInteractiveInput()
            let resolvedRunMode = configuration.resolvedRunMode(
                stdinIsTerminal: interactiveInputAvailable
            )

            switch resolvedRunMode {
            case .chat:
                AgentOutput.silenceInheritedProcessOutput(
                    keepStandardError: configuration.verboseLogging
                )
                try await AgentRuntimeLauncher.runTerminalChat(
                    configuration: configuration,
                    stdinIsTerminal: interactiveInputAvailable
                )
                return
            case .acp:
                if !configuration.verboseLogging {
                    AgentOutput.silenceInheritedProcessError()
                }
                break
            }

            await AgentRuntimeLauncher.runACP(configuration: configuration)
        } catch {
            AgentOutput.standardError.writeString(
                "ZenCODE: \(error.localizedDescription)\n\(ZenCODEDoctorRunner.troubleshootingHint)"
            )
            Foundation.exit(1)
        }
    }

    public static func shouldRunAsCommandLine(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        guard let executablePath = arguments.first else {
            return false
        }
        let sanitizedArguments = ZenCODECommandLineArgumentSanitizer.sanitized(arguments)

        let executableURL = URL(fileURLWithPath: executablePath)
            .standardizedFileURL
        guard executableURL.lastPathComponent == "ZenCODE" else {
            return false
        }

        if sanitizedArguments.dropFirst().contains(where: isCommandLineOption(_:)) {
            return true
        }

        if !executableURL.path.contains(".app/Contents/MacOS/") {
            return true
        }

        if sanitizedArguments.count == 1,
           ZenCODECommandLineArgumentSanitizer.containsCocoaLaunchArguments(arguments) {
            return false
        }

        return isatty(STDIN_FILENO) == 1
    }

    private static func isCommandLineOption(_ argument: String) -> Bool {
        argument == "-h"
            || argument == "--help"
            || argument == "--version"
            || argument == "--doctor"
            || argument == "--model"
            || argument == "--agent"
            || argument == "--bearer-token"
            || argument == "--acp"
            || argument == "--cwd"
            || argument == "--skills"
            || argument == "--max-tool-rounds"
            || argument == "--max-output-tokens"
            || argument == "--verbose"
    }
}
