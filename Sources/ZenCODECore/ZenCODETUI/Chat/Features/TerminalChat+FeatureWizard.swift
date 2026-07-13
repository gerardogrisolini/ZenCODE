//
//  TerminalChat+FeatureWizard.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    func runFeatureWizard() async -> TerminalFeatureCommandResult {
        guard let template = TerminalCheckboxMenu.selectOne(
            title: "Feature template",
            items: [
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.mcpBridge,
                    title: "MCP Bridge",
                    detail: "Expose tools from an HTTP or stdio MCP service"
                ),
                TerminalCheckboxMenuItem(
                    value: FeatureWizardTemplate.basic,
                    title: "Basic Swift Feature",
                    detail: "Create a small editable Swift tool scaffold"
                )
            ],
            selected: .mcpBridge,
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
            defaultValue: template.defaultDescription(displayName: displayName)
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

            guard let transport = TerminalCheckboxMenu.selectOne(
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
                        detail: "Launch an MCP server executable"
                    )
                ],
                selected: .http,
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            ) else {
                return await cancelledFeatureWizard()
            }

            switch transport {
            case .http:
                guard let endpointURL = await promptFeatureLine("MCP endpoint URL", required: true) else {
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
                if let rawEnvironment = await promptFeatureLine("Environment KEY=value pairs", defaultValue: "") {
                    let parsedEnvironment = Self.featureWizardEnvironment(rawEnvironment)
                    if !parsedEnvironment.isEmpty {
                        arguments["environment"] = parsedEnvironment
                    }
                }
            }
        }

        let shouldEnable = await promptFeatureYesNo("Enable feature after build?", defaultValue: true) ?? false
        let shouldSelect = shouldEnable
            ? (await promptFeatureYesNo("Select feature for this session?", defaultValue: true) ?? false)
            : false
        guard let requirements = await promptFeatureLine(
            "Goal / requirements (empty to edit the generated prompt)",
            required: false
        ) else {
            return await cancelledFeatureWizard()
        }

        return await createFeatureFromWizard(
            id: id,
            displayName: displayName,
            arguments: arguments,
            shouldEnable: shouldEnable,
            shouldSelect: shouldSelect,
            requirements: requirements.nilIfBlank
        )
    }

    func createFeatureFromWizard(
        id: String,
        displayName: String,
        arguments: [String: Any],
        shouldEnable: Bool,
        shouldSelect: Bool,
        requirements: String?
    ) async -> TerminalFeatureCommandResult {
        var scaffoldArguments = arguments
        scaffoldArguments["build"] = true
        scaffoldArguments["enable"] = shouldEnable
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
        guard scaffoldReport.ok ?? true else {
            return .none
        }

        let enabled = scaffoldReport.enabled ?? false
        if enabled {
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }

        let selected = shouldSelect && enabled
        if selected {
            var nextSelection = selectedToolKeys
            nextSelection.insert(TerminalToolSelectionCatalog.featurePackageKey(id: id))
            await applyToolSelection(nextSelection)
        }

        await writeSystemMessage(
            Self.renderFeatureWizardCompletion(
                id: id,
                built: scaffoldReport.built ?? false,
                enabled: enabled,
                selected: selected
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
                requirements: requirements
            ),
            requirements: requirements
        )
    }

    private func cancelledFeatureWizard() async -> TerminalFeatureCommandResult {
        await writeSystemMessage("Feature creation cancelled.\n")
        return .none
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
            guard let line = interactiveReader.readLine(prompt: prompt) else {
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
            guard let line = interactiveReader.readLine(prompt: "\(label) [\(suffix)]: ") else {
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
