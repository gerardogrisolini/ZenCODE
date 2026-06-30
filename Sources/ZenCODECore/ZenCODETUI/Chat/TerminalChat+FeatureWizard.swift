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
            reservedBottomRows: statusBar.reservedRowsForOverlay()
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        guard let id = promptFeatureLine("Feature id", required: true) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }
        let defaultDisplayName = Self.featureWizardDisplayName(from: id)
        guard let displayName = promptFeatureLine(
            "Display name",
            defaultValue: defaultDisplayName
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }
        let description = promptFeatureLine(
            "Description",
            defaultValue: template.defaultDescription(displayName: displayName)
        )
        guard let description else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        var arguments: [String: Any] = [
            "id": id,
            "displayName": displayName,
            "description": description
        ]

        switch template {
        case .basic:
            let defaultToolName = "\(Self.featureWizardPrefix(from: id))run"
            guard let toolName = promptFeatureLine(
                "Tool name",
                defaultValue: defaultToolName
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }
            arguments["toolName"] = toolName
        case .mcpBridge:
            arguments["template"] = "mcp-bridge"
            let serviceName = promptFeatureLine(
                "Service name",
                defaultValue: displayName
            )
            guard let serviceName else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }
            arguments["serviceName"] = serviceName

            guard let toolPrefix = promptFeatureLine(
                "Tool prefix",
                defaultValue: Self.featureWizardPrefix(from: id)
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
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
                reservedBottomRows: statusBar.reservedRowsForOverlay()
            ) else {
                writeSystemMessage("Feature creation cancelled.\n")
                return .none
            }

            switch transport {
            case .http:
                guard let endpointURL = promptFeatureLine("MCP endpoint URL", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return .none
                }
                arguments["endpointURL"] = endpointURL
            case .stdio:
                guard let executablePath = promptFeatureLine("MCP executable path", required: true) else {
                    writeSystemMessage("Feature creation cancelled.\n")
                    return .none
                }
                arguments["executablePath"] = executablePath
                if let rawArguments = promptFeatureLine("Executable arguments", defaultValue: "") {
                    let parsedArguments = Self.featureWizardArguments(rawArguments)
                    if !parsedArguments.isEmpty {
                        arguments["arguments"] = parsedArguments
                    }
                }
                if let rawEnvironment = promptFeatureLine("Environment KEY=value pairs", defaultValue: "") {
                    let parsedEnvironment = Self.featureWizardEnvironment(rawEnvironment)
                    if !parsedEnvironment.isEmpty {
                        arguments["environment"] = parsedEnvironment
                    }
                }
            }
        }

        let shouldBuild = true
        let shouldEnable = promptFeatureYesNo("Enable feature after build?", defaultValue: true) ?? false
        let shouldSelect = shouldEnable
            ? (promptFeatureYesNo("Select feature for this session?", defaultValue: true) ?? false)
            : false
        guard let requirements = promptFeatureLine(
            "Goal / requirements (empty to edit the generated prompt)",
            required: false
        ) else {
            writeSystemMessage("Feature creation cancelled.\n")
            return .none
        }

        return await createFeatureFromWizard(
            id: id,
            displayName: displayName,
            arguments: arguments,
            shouldBuild: shouldBuild,
            shouldEnable: shouldEnable,
            shouldSelect: shouldSelect,
            requirements: requirements.nilIfBlank
        )
    }

    func createFeatureFromWizard(
        id: String,
        displayName: String,
        arguments: [String: Any],
        shouldBuild: Bool,
        shouldEnable: Bool,
        shouldSelect: Bool,
        requirements: String?
    ) async -> TerminalFeatureCommandResult {
        guard let scaffoldOutput = await executeFeatureManagementTool(
            name: "feature.scaffold",
            arguments: arguments
        ) else {
            return .none
        }
        writeSystemMessage(Self.renderFeatureManagementToolOutput(name: "feature.scaffold", output: scaffoldOutput))
        guard let scaffoldReport = Self.decodeFeatureOutput(
            SwiftFeatureScaffoldReport.self,
            from: scaffoldOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        ) else {
            return .none
        }

        guard await runFeatureManagementTool(
            name: "feature.validate",
            arguments: ["id": id]
        ) else {
            return .none
        }

        if shouldBuild {
            guard await runFeatureManagementTool(
                name: "feature.build",
                arguments: ["id": id]
            ) else {
                return .none
            }
        }

        if shouldEnable {
            guard await runFeatureManagementTool(
                name: "feature.enable",
                arguments: ["id": id]
            ) else {
                return .none
            }
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
        }

        if shouldSelect {
            var nextSelection = selectedToolKeys
            nextSelection.insert(TerminalToolSelectionCatalog.featurePackageKey(id: id))
            await applyToolSelection(nextSelection)
        }

        writeSystemMessage(
            Self.renderFeatureWizardCompletion(
                id: id,
                built: shouldBuild,
                enabled: shouldEnable,
                selected: shouldSelect
            )
        )

        let implementationPrompt = Self.featureImplementationPrompt(
            id: id,
            displayName: displayName,
            directoryPath: scaffoldReport.directoryPath,
            manifestPath: scaffoldReport.manifestPath,
            sourcePath: scaffoldReport.sourcePath,
            toolName: scaffoldReport.toolName,
            requirements: requirements
        )
        if requirements != nil {
            return .runPrompt(implementationPrompt)
        }
        return .prefillPrompt(implementationPrompt)
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
        writeSystemMessage(Self.renderFeatureManagementToolOutput(name: name, output: output))
        return Self.featureManagementToolSucceeded(name: name, output: output)
    }

    func executeFeatureManagementTool(
        name: String,
        arguments: [String: Any]
    ) async -> String? {
        do {
            return try await SwiftFeatureRuntime().executeManagementTool(
                toolCall: DirectAgentToolCall(
                    id: "terminal-\(name)-\(UUID().uuidString)",
                    name: name,
                    argumentsObject: arguments,
                    argumentsJSON: jsonString(from: arguments)
                )
            )
        } catch {
            writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return nil
        }
    }

    func promptFeatureLine(
        _ label: String,
        defaultValue: String? = nil,
        required: Bool = false
    ) -> String? {
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
            writeFailureMessage("ZenCODE: \(label) is required.\n")
        }
    }

    func promptFeatureYesNo(
        _ label: String,
        defaultValue: Bool
    ) -> Bool? {
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
                writeFailureMessage("ZenCODE: answer yes or no.\n")
            }
        }
    }
}
