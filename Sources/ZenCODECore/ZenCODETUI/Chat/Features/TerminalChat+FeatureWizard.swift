//
//  TerminalChat+FeatureWizard.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    func runFeatureWizard() async -> TerminalFeatureCommandResult {
        guard let rawRequirements = await promptFeatureLine(
            "Goal / requirements (optional)",
            required: false
        ) else {
            return await cancelledFeatureWizard()
        }
        let requirements = rawRequirements.nilIfBlank

        guard let template = await TerminalCheckboxMenu.selectOneOffActor(
            title: "Feature template",
            items: [
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.basic,
                    title: "Basic Swift Feature",
                    detail: "Create an editable Swift tool, then let Builder implement it"
                ),
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.mcpBridge,
                    title: "MCP Bridge",
                    detail: "Expose tools from an HTTP or stdio MCP service"
                )
            ],
            selected: .basic,
            reservedBottomRows: await statusBar.reservedRowsForOverlay()
        ) else {
            return await cancelledFeatureWizard()
        }

        guard let id = await promptFeatureLine("Feature id", required: true) else {
            return await cancelledFeatureWizard()
        }
        let defaultDisplayName = Self.featureWizardDisplayName(from: id)
        guard let displayName = await promptFeatureLine(
            "Display name",
            defaultValue: defaultDisplayName
        ) else {
            return await cancelledFeatureWizard()
        }
        let description = await promptFeatureLine(
            "Description",
            defaultValue: Self.featureWizardDescription(
                requirements: requirements,
                fallback: template.defaultDescription(displayName: displayName)
            )
        )
        guard let description else {
            return await cancelledFeatureWizard()
        }

        var arguments: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": description
        ]

        switch template {
        case .basic:
            let defaultToolName = "\(Self.featureWizardPrefix(from: id))run"
            guard let toolName = await promptFeatureLine(
                "Tool name",
                defaultValue: defaultToolName
            ) else {
                return await cancelledFeatureWizard()
            }
            arguments["toolName"] = toolName
        case .mcpBridge:
            arguments["template"] = "mcp-bridge"
            let serviceName = await promptFeatureLine(
                "Service name",
                defaultValue: displayName
            )
            guard let serviceName else {
                return await cancelledFeatureWizard()
            }
            arguments["serviceName"] = serviceName

            guard let toolPrefix = await promptFeatureLine(
                "Tool prefix",
                defaultValue: Self.featureWizardPrefix(from: id)
            ) else {
                return await cancelledFeatureWizard()
            }
            arguments["toolPrefix"] = toolPrefix

            guard let transport = await TerminalCheckboxMenu.selectOneOffActor(
                title: "MCP transport",
                items: [
                    TerminalCheckboxMenuItem(
                        value: FeatureWizardTransport.http,
                        title: "HTTP",
                        detail: "Connect to an MCP endpoint URL"
                    ),
                    TerminalCheckboxMenuItem(
                        value: FeatureWizardTransport.stdio,
                        title: "Stdio",
                        detail: "Launch an MCP server executable using ZenCODE's environment"
                    )
                ],
                selected: .http,
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            ) else {
                return await cancelledFeatureWizard()
            }

            switch transport {
            case .http:
                guard let endpointURL = await promptFeatureEndpointURL() else {
                    return await cancelledFeatureWizard()
                }
                arguments["endpointURL"] = endpointURL
            case .stdio:
                guard let executablePath = await promptFeatureLine("MCP executable path", required: true) else {
                    return await cancelledFeatureWizard()
                }
                arguments["executablePath"] = executablePath
                if let rawArguments = await promptFeatureLine("Executable arguments", defaultValue: "") {
                    let parsedArguments = Self.featureWizardArguments(rawArguments)
                    if !parsedArguments.isEmpty {
                        arguments["arguments"] = parsedArguments
                    }
                }
            }
        }

        let activationPrompt = switch template {
        case .basic:
            "Enable feature after implementation and a successful build?"
        case .mcpBridge:
            "Enable and select feature if the initial build succeeds?"
        }
        let activateAfterSuccessfulBuild = await promptFeatureYesNo(
            activationPrompt,
            defaultValue: true
        ) ?? false

        return await createFeatureFromWizard(
            template: template,
            id: id,
            displayName: displayName,
            arguments: arguments,
            activateAfterSuccessfulBuild: activateAfterSuccessfulBuild,
            requirements: requirements
        )
    }

    func createFeatureFromWizard(
        template: FeatureWizardTemplate,
        id: String,
        displayName: String,
        arguments: [String: Any],
        activateAfterSuccessfulBuild: Bool,
        requirements: String?
    ) async -> TerminalFeatureCommandResult {
        let plan = FeatureWizardCreationPlan(
            template: template,
            activateAfterSuccessfulBuild: activateAfterSuccessfulBuild
        )
        var scaffoldArguments = arguments
        scaffoldArguments["build"] = plan.buildsScaffold
        scaffoldArguments["enable"] = plan.enablesScaffold
        guard let scaffoldOutput = await executeFeatureManagementTool(
            name: "feature.scaffold",
            arguments: scaffoldArguments
        ) else {
            return .none
        }
        await writeSystemMessage(Self.renderFeatureManagementToolOutput(name: "feature.scaffold", output: scaffoldOutput))
        guard let scaffoldReport = Self.decodeFeatureOutput(
            SwiftFeatureScaffoldReport.self,
            from: scaffoldOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            await writeFailureMessage("ZenCODE: could not decode the feature.scaffold report.\n")
            return .none
        }

        if plan.runsImplementationPrompt {
            await writeSystemMessage(
                Self.renderFeatureDraftCompletion(
                    id: id,
                    enableAfterBuild: plan.enablesAfterImplementation
                )
            )
            return Self.featurePromptResult(
                Self.featureImplementationPrompt(
                    id: id,
                    displayName: displayName,
                    directoryPath: scaffoldReport.directoryPath,
                    manifestPath: scaffoldReport.manifestPath,
                    sourcePath: scaffoldReport.sourcePath,
                    toolName: scaffoldReport.toolName,
                    enableAfterBuild: plan.enablesAfterImplementation,
                    requirements: requirements
                ),
                requirements: requirements
            )
        }

        guard scaffoldReport.ok == true,
              scaffoldReport.built == true else {
            await writeSystemMessage(
                "The MCP bridge scaffold was preserved so Builder can inspect and repair it.\n"
            )
            return Self.featurePromptResult(
                Self.featureMCPRepairPrompt(
                    report: scaffoldReport,
                    displayName: displayName,
                    enableAfterBuild: activateAfterSuccessfulBuild,
                    requirements: requirements
                ),
                requirements: requirements
            )
        }

        let enabled = scaffoldReport.enabled ?? false
        let featureSelectionKey = TerminalToolSelectionCatalog.featurePackageKey(id: id)
        let shouldSelect = plan.selectsScaffold && enabled
        if shouldSelect {
            var nextSelection = selectedToolKeys
            nextSelection.insert(featureSelectionKey)
            await applyToolSelection(nextSelection)
        } else if enabled {
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }
        let selected = shouldSelect && selectedToolKeys.contains(featureSelectionKey)

        await writeSystemMessage(
            Self.renderFeatureWizardCompletion(
                id: id,
                built: scaffoldReport.built ?? false,
                enabled: enabled,
                selected: selected
            )
        )
        return .none
    }

    private func cancelledFeatureWizard() async -> TerminalFeatureCommandResult {
        await writeSystemMessage("Feature creation cancelled.\n")
        return .none
    }

    private func promptFeatureEndpointURL() async -> String? {
        while let endpointURL = await promptFeatureLine(
            "MCP endpoint URL (without embedded credentials)",
            required: true
        ) {
            switch SwiftFeatureRuntime.mcpBridgeEndpointIssue(endpointURL) {
            case nil:
                return endpointURL
            case .invalidHTTPURL:
                await writeFailureMessage(
                    "ZenCODE: enter an absolute http:// or https:// MCP endpoint URL.\n"
                )
            case .embeddedCredentials:
                await writeFailureMessage(
                    "ZenCODE: do not embed credentials, tokens, API keys, or passwords in the endpoint URL. Configure them outside generated source.\n"
                )
            }
        }
        return nil
    }

    @discardableResult
    func runFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> Bool {
        guard let output = await executeFeatureManagementTool(
            name: name,
            arguments: arguments
        ) else {
            return false
        }
        await writeSystemMessage(Self.renderFeatureManagementToolOutput(name: name, output: output))
        return Self.featureManagementToolSucceeded(name: name, output: output)
    }

    func executeFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> String? {
        do {
            return try await featureRuntime.executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "terminal-\(name)-\(UUID().uuidString)",
                    name: name,
                    argumentsObject: arguments,
                    argumentsJSON: jsonString(from: arguments)
                )
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return nil
        }
    }

    func promptFeatureLine(
        _ label: String,
        defaultValue: String? = nil,
        required: Bool = false
    ) async -> String? {
        while true {
            let prompt = defaultValue?.isEmpty == false
                ? "\(label) [\(defaultValue!)]: "
                : "\(label): "
            guard let line = await Self.readLineOffActor(
                reader: interactiveReader,
                prompt: prompt
            ) else {
                return nil
            }
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
            if let defaultValue {
                return defaultValue
            }
            guard required else {
                return ""
            }
            await writeFailureMessage("ZenCODE: \(label) is required.\n")
        }
    }

    func promptFeatureYesNo(
        _ label: String,
        defaultValue: Bool
    ) async -> Bool? {
        let suffix = defaultValue ? "Y/n" : "y/N"
        while true {
            guard let line = await Self.readLineOffActor(
                reader: interactiveReader,
                prompt: "\(label) [\(suffix)]: "
            ) else {
                return nil
            }
            switch line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "":
                return defaultValue
            case "y", "yes", "true", "1":
                return true
            case "n", "no", "false", "0":
                return false
            default:
                await writeFailureMessage("ZenCODE: answer yes or no.\n")
            }
        }
    }
}
