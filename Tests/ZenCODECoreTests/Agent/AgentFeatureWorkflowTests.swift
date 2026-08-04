//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

extension AgentConfigurationTests {
    @Test
    func featureCommandWarnsWhenBuilderIsNotActive() {
        #expect(!TerminalChat.renderFeatureCommandUsage().contains("adopt"))
        #expect(TerminalChat.renderFeatureCommandUnavailableForAgent().contains("Builder agent"))
        #expect(!TerminalChat.renderFeatureCommandUnavailableForAgent().contains("/tools"))
    }

    @Test
    func featureCommandIsVisibleOnlyWithBuilderAgent() {
        let normalCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        let builderCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: true,
            telegramEnabled: false
        ).map(\.command)

        #expect(!normalCommands.contains("/feature"))
        #expect(!builderCommands.contains("/features"))
        #expect(builderCommands.contains("/feature"))
    }

    @Test
    func featureWizardPlansBuildOnlyCompleteMCPBridges() {
        let enabledBasic = FeatureWizardCreationPlan(
            template: .basic,
            activateAfterSuccessfulBuild: true
        )
        let disabledBasic = FeatureWizardCreationPlan(
            template: .basic,
            activateAfterSuccessfulBuild: false
        )
        let enabledBridge = FeatureWizardCreationPlan(
            template: .mcpBridge,
            activateAfterSuccessfulBuild: true
        )
        let disabledBridge = FeatureWizardCreationPlan(
            template: .mcpBridge,
            activateAfterSuccessfulBuild: false
        )

        #expect(!enabledBasic.buildsScaffold)
        #expect(!enabledBasic.enablesScaffold)
        #expect(!enabledBasic.selectsScaffold)
        #expect(enabledBasic.runsImplementationPrompt)
        #expect(enabledBasic.enablesAfterImplementation)
        #expect(!disabledBasic.enablesAfterImplementation)

        #expect(enabledBridge.buildsScaffold)
        #expect(enabledBridge.enablesScaffold)
        #expect(enabledBridge.selectsScaffold)
        #expect(!enabledBridge.runsImplementationPrompt)
        #expect(disabledBridge.buildsScaffold)
        #expect(!disabledBridge.enablesScaffold)
        #expect(!disabledBridge.selectsScaffold)
    }

    @Test
    func featureWizardRejectsCredentialBearingMCPEndpoints() {
        #expect(SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools") == nil)
        #expect(SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools?project=zen") == nil)
        #expect(SwiftFeatureRuntime.mcpBridgeEndpointIssue("mcp.example.com/tools") == .invalidHTTPURL)
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://user:password@mcp.example.com/tools")
                == .embeddedCredentials
        )
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools?access_token=secret")
                == .embeddedCredentials
        )
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools?API_KEY=secret")
                == .embeddedCredentials
        )
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools?client-secret=secret")
                == .embeddedCredentials
        )
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools?key=secret")
                == .embeddedCredentials
        )
        #expect(
            SwiftFeatureRuntime.mcpBridgeEndpointIssue("https://mcp.example.com/tools#access_token=secret")
                == .embeddedCredentials
        )
    }

    @Test
    func featureWizardDescriptionUsesGoalWithoutGrowingUnbounded() {
        #expect(
            TerminalChat.featureWizardDescription(
                requirements: "  Return   the current\nbranch  ",
                fallback: "Fallback"
            ) == "Return the current branch"
        )
        #expect(
            TerminalChat.featureWizardDescription(
                requirements: nil,
                fallback: "Fallback"
            ) == "Fallback"
        )
        let longDescription = TerminalChat.featureWizardDescription(
            requirements: String(repeating: "x", count: 200),
            fallback: "Fallback"
        )
        #expect(longDescription.count == 160)
        #expect(longDescription.hasSuffix("..."))
    }

        @Test
    func savedSessionCommandTreatsSaveAsActiveSessionUpdate() {
                #expect(TerminalChat.savedSessionCommandAction(rawArguments: "") == .list)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "delete") == .delete)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: " save ") == .saveActive)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: " compact ") == .compact)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: " new ") == .newSession)
        #expect(
            TerminalChat.savedSessionCommandAction(rawArguments: "daily checkpoint")
                == .saveNamed("daily checkpoint")
        )
    }

    @Test
    func savedSessionCommandParsesCheckpointSubcommands() {
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "tree") == .tree)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "branches") == .branches)
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "checkpoint") == .checkpoint(label: nil))
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "checkpoint stable") == .checkpoint(label: "stable"))
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "restore a1b2c3d4") == .restore(entryID: "a1b2c3d4"))
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "restore") == .restore(entryID: ""))
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "restore a1b2c3d4") == .restore(entryID: "a1b2c3d4"))
        #expect(TerminalChat.savedSessionCommandAction(rawArguments: "restore 2") == .restore(entryID: "2"))
    }

    @Test
    func derivedSessionNameUsesFirstUserPrompt() {
        let messages = [
            AgentRuntimeMessage(role: .system, content: "system prompt"),
            AgentRuntimeMessage(role: .user, content: "Fix the login bug"),
            AgentRuntimeMessage(role: .assistant, content: "Sure")
        ]
        #expect(
            TerminalChat.derivedSessionName(fromFirstPromptIn: messages) == "Fix the login bug"
        )
    }

    @Test
    func derivedSessionNameReturnsNilWithoutUserPrompt() {
        let messages = [
            AgentRuntimeMessage(role: .system, content: "system prompt"),
            AgentRuntimeMessage(role: .assistant, content: "Hello")
        ]
        #expect(TerminalChat.derivedSessionName(fromFirstPromptIn: messages) == nil)
        #expect(TerminalChat.derivedSessionName(fromFirstPromptIn: []) == nil)
    }

    @Test
    func derivedSessionNameCollapsesWhitespaceAndIgnoresBlankPrompts() {
        #expect(
            TerminalChat.derivedSessionName(fromFirstPrompt: "  hello\n   world  ") == "hello world"
        )
        #expect(TerminalChat.derivedSessionName(fromFirstPrompt: "   \n  ") == nil)
    }

    @Test
    func derivedSessionNameTruncatesLongPromptsAtWordBoundary() {
                let prompt = "Please refactor the entire authentication subsystem and add tests"
        let name = TerminalChat.derivedSessionName(fromFirstPrompt: prompt, limit: 40)
        #expect(name == "Please refactor the entire")
        #expect((name?.count ?? .max) <= 40)
    }

    @Test
    func featureWizardOutputsHumanReadableStatusInsteadOfJSON() {
        let scaffoldOutput = """
        {
          "directoryPath" : "/tmp/features/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "packagePath" : "/tmp/features/test1/Package.swift",
          "sourcePath" : "/tmp/features/test1/Sources/Test1/main.swift",
          "toolName" : "test1.run"
        }
        """
        let validationOutput = """
        {
          "errors" : [],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "ok" : true,
          "tools" : [
            "test1.run"
          ],
          "warnings" : [
            "Executable has not been built yet: /tmp/features/test1/.build/release/test1"
          ]
        }
        """
        let buildOutput = """
        {
          "command" : [
            "swift",
            "build"
          ],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "exitCode" : 0,
          "id" : "test1",
          "ok" : true,
          "stderr" : "",
          "stdout" : "Building for production...",
          "timedOut" : false,
          "workingDirectory" : "/tmp/features/test1"
        }
        """
        let failedBuildOutput = """
        {
          "command" : [
            "swift",
            "build"
          ],
          "executablePath" : "/tmp/features/test1/.build/release/test1",
          "exitCode" : 1,
          "id" : "test1",
          "ok" : false,
          "stderr" : "compile error",
          "stdout" : "",
          "timedOut" : false,
          "workingDirectory" : "/tmp/features/test1"
        }
        """
        let deleteOutput = """
        {
          "directoryPath" : "/tmp/features/test1",
          "id" : "test1",
          "manifestPath" : "/tmp/features/test1/feature.json",
          "ok" : true,
          "removed" : true,
          "wasEnabled" : false
        }
        """

        let scaffoldRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.scaffold",
            output: scaffoldOutput
        )
        let validationRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.validate",
            output: validationOutput
        )
        let buildRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.build",
            output: buildOutput
        )
        let deleteRendered = TerminalChat.renderFeatureManagementToolOutput(
            name: "feature.delete",
            output: deleteOutput
        )
        let completion = TerminalChat.renderFeatureWizardCompletion(
            id: "test1",
            built: true,
            enabled: false,
            selected: false
        )

        #expect(scaffoldRendered.contains("Created Swift feature 'test1'."))
        #expect(scaffoldRendered.contains("Tool: test1.run"))
        #expect(!scaffoldRendered.contains("{"))
        #expect(validationRendered.contains("Validated Swift feature 'test1'."))
        #expect(!validationRendered.contains("Executable has not been built yet"))
        #expect(buildRendered.contains("Built Swift feature 'test1'."))
        #expect(!buildRendered.contains("stdout"))
        #expect(deleteRendered.contains("Deleted Swift feature 'test1'."))
        #expect(!deleteRendered.contains("{"))
        #expect(completion.contains("not active yet"))
        #expect(TerminalChat.featureManagementToolSucceeded(name: "feature.build", output: buildOutput))
        #expect(!TerminalChat.featureManagementToolSucceeded(name: "feature.build", output: failedBuildOutput))
    }

    @Test
    func featureImplementationPromptCarriesScaffoldContextAndRequirements() {
        let prompt = TerminalChat.featureImplementationPrompt(
            id: "test1",
            displayName: "Test1",
            directoryPath: "/tmp/features/test1",
            manifestPath: "/tmp/features/test1/feature.json",
            sourcePath: "/tmp/features/test1/Sources/Test1/main.swift",
            toolName: "test1.run",
            enableAfterBuild: true,
            requirements: "Return the current git branch as JSON."
        )
        let draftPrompt = TerminalChat.featureImplementationPrompt(
            id: "test1",
            displayName: "Test1",
            directoryPath: "/tmp/features/test1",
            manifestPath: "/tmp/features/test1/feature.json",
            sourcePath: "/tmp/features/test1/Sources/Test1/main.swift",
            toolName: "test1.run",
            enableAfterBuild: false,
            requirements: nil
        )

        #expect(prompt.contains("/tmp/features/test1/Sources/Test1/main.swift"))
        #expect(prompt.contains("test1.run"))
        #expect(prompt.contains("Return the current git branch as JSON."))
        #expect(prompt.contains("feature.validate"))
        #expect(prompt.contains("feature.build"))
        #expect(prompt.contains("Do not enable or expose placeholder"))
        #expect(prompt.contains("enable `test1` with `feature.enable`"))
        #expect(prompt.contains("do not call `feature.reload`"))
        #expect(draftPrompt.contains("Leave `test1` disabled"))
        #expect(draftPrompt.hasSuffix("Goal / requirements:"))
    }

    @Test
    func failedMCPScaffoldProducesRepairPromptWithDiagnostics() {
        let report = SwiftFeatureScaffoldReport(
            id: "broken-mcp",
            directoryPath: "/tmp/features/broken-mcp",
            manifestPath: "/tmp/features/broken-mcp/feature.json",
            packagePath: "/tmp/features/broken-mcp/Package.swift",
            sourcePath: "/tmp/features/broken-mcp/Sources/BrokenMcp/main.swift",
            toolName: "broken.",
            ok: false,
            built: false,
            enabled: false,
            validation: SwiftFeatureValidationReport(
                id: "broken-mcp",
                manifestPath: "/tmp/features/broken-mcp/feature.json",
                executablePath: nil,
                errors: ["Invalid bridge configuration"],
                warnings: [],
                tools: []
            )
        )

        let prompt = TerminalChat.featureMCPRepairPrompt(
            report: report,
            displayName: "Broken MCP",
            enableAfterBuild: true,
            requirements: "Connect to the internal service."
        )

        #expect(prompt.contains("Repair the generated MCP bridge"))
        #expect(prompt.contains("Invalid bridge configuration"))
        #expect(prompt.contains("without embedding credentials"))
        #expect(prompt.contains("Stdio bridges inherit"))
        #expect(prompt.contains("enable `broken-mcp`"))
        #expect(prompt.contains("Connect to the internal service."))
    }

    @Test
    func featurePackageSelectionDetailsShowOnlyDescriptions() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "xcode-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["xcode."],
                    discoversToolsAtRuntime: true
                ),
                featureStatus(
                    id: "figma-tools",
                    source: .bundled,
                    tools: ["figma.get_code", "figma.get_variable_defs"],
                    toolNamePrefixes: ["figma."],
                    discoversToolsAtRuntime: true
                )
            ]
        )

        let xcodeItem = try #require(items.first { $0.title == "Xcode" })
        let figmaItem = try #require(items.first { $0.title == "Figma" })
        let xcodeDetail = try #require(xcodeItem.detail)
        let figmaDetail = try #require(figmaItem.detail)

        #expect(xcodeDetail == "Build, test, preview, and inspect Xcode projects.")
        #expect(figmaDetail == "Inspect Figma files, frames, and design data.")
        #expect(!xcodeDetail.contains(";"))
        #expect(!figmaDetail.contains(";"))
        #expect(!xcodeDetail.contains("discovers tools at runtime"))
        #expect(!xcodeDetail.contains("1 tool: xcode."))
        #expect(!figmaDetail.contains("2 tools: figma.get_code, figma.get_variable_defs"))
    }

    @Test
    func toolSelectionCatalogHidesDisabledFeaturePackages() {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "enabled-clock",
                    displayName: "Enabled Clock",
                    source: .generated,
                    tools: ["clock.now"]
                ),
                featureStatus(
                    id: "disabled-clock",
                    displayName: "Disabled Clock",
                    source: .generated,
                    tools: ["clock.disabled"],
                    enabled: false
                )
            ]
        )

        #expect(items.map(\.title).contains("Enabled Clock"))
        #expect(!items.map(\.title).contains("Disabled Clock"))
    }

    @Test
    func featureListShowsBundledAndGeneratedPackagesIncludingDisabled() throws {
        let statuses = [
            featureStatus(
                id: "design-tools",
                source: .bundled,
                tools: [],
                toolNamePrefixes: ["design."],
                discoversToolsAtRuntime: true,
                enabled: false
            ),
            featureStatus(
                id: "git-tools",
                source: .bundled,
                tools: ["git.status"]
            ),
            featureStatus(
                id: "custom-linear",
                displayName: "Linear",
                source: .generated,
                tools: ["linear.issue.list"]
            )
        ]

        let rendered = TerminalChat.renderFeatureStatusList(statuses)

        #expect(rendered.contains("Design Tools [design-tools] - disabled, bundled, discovers tools at runtime"))
        #expect(rendered.contains("Linear [custom-linear] - enabled, generated, editable, 1 tool: linear.issue.list"))
        #expect(rendered.contains("Git [git-tools] - enabled, bundled, 1 tool: git.status"))
        #expect(!rendered.contains("core"))
        #expect(rendered.contains("Run /feature list to open the enable/disable menu."))
        #expect(try TerminalChat.resolvedFeatureID("Design Tools", statuses: statuses) == "design-tools")
        #expect(try TerminalChat.resolvedFeatureID("Linear", statuses: statuses) == "custom-linear")
    }

    @Test
    func featureCheckboxItemUsesToolSelectionDescription() {
        let status = featureStatus(
            id: "jira-tools",
            description: "Query and manage Jira issues and projects.",
            source: .bundled,
            tools: ["jira.read", "jira.search", "jira.signOut"]
        )
        let item = TerminalChat.featureCheckboxItem(
            status
        )
        let toolsItem = TerminalChat.toolSelectionItems(featureStatuses: [status])
            .first { $0.title == "Jira" }

        #expect(item.value == "jira-tools")
        #expect(item.title == "Jira [jira-tools]")
        #expect(item.detail == toolsItem?.detail)
        #expect(item.groupTitle == nil)
    }

    @Test
    func featureStatusSortOrderKeepsVisibleFeaturesUngrouped() {
        let statuses = [
            featureStatus(id: "figma-tools", source: .bundled, tools: []),
            featureStatus(id: "git-tools", source: .bundled, tools: []),
            featureStatus(id: "jira-tools", source: .bundled, tools: []),
            featureStatus(id: "search-tools", source: .bundled, tools: []),
            featureStatus(id: "custom-linear", displayName: "Linear", source: .generated, tools: []),
            featureStatus(
                id: "design-tools",
                source: .generated,
                tools: [],
                adoptedFrom: "design-tools"
            )
        ]

        let items = statuses
            .sorted(by: TerminalChat.featureStatusSortOrder)
            .map(TerminalChat.featureCheckboxItem)

        #expect(items.map(\.groupTitle) == [
            nil,
            nil,
            nil,
            nil,
            nil,
            nil
        ])
        #expect(items.map(\.title) == [
            "Design Tools [design-tools]",
            "Figma [figma-tools]",
            "Git [git-tools]",
            "Jira [jira-tools]",
            "Linear [custom-linear]",
            "Search [search-tools]"
        ])
    }

    @Test
    func activeToolRenderingCountsUndiscoveredRuntimePackagesAsZero() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "figma-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["figma."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let selectedKeys = try TerminalChat.parseToolSelection("figma", items: items)
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let activeToolNames = TerminalChat.resolvedActiveToolNames(
            fallbackAllowedToolNames: allowedToolNames,
            activeDescriptors: []
        )
        let rendered = TerminalChat.renderActiveTools(
            activeToolNames,
            items: items,
            selectedKeys: selectedKeys
        )

        #expect(rendered.contains("Figma (0)"))
        #expect(!rendered.contains("Figma (1)"))
        #expect(rendered.hasPrefix("Active tools: Figma (0)"))
        #expect(!rendered.contains("\n  Figma"))
    }

    @Test
    func activeToolRenderingCountsResolvedRuntimeDescriptors() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "git-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["git."],
                    discoversToolsAtRuntime: true
                ),
                featureStatus(
                    id: "swift-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["swift."],
                    discoversToolsAtRuntime: true
                ),
                featureStatus(
                    id: "web-tools",
                    source: .bundled,
                    tools: [],
                    toolNamePrefixes: ["web."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let selectedKeys = try TerminalChat.parseToolSelection(
            "git swift web",
            items: items
        )
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let activeToolNames = TerminalChat.resolvedActiveToolNames(
            fallbackAllowedToolNames: allowedToolNames,
            activeDescriptors: [
                DirectToolDescriptor(
                    name: "git.status",
                    description: "Git status",
                    inputSchema: "{}"
                ),
                DirectToolDescriptor(
                    name: "git.diff",
                    description: "Git diff",
                    inputSchema: "{}"
                ),
                DirectToolDescriptor(
                    name: "swift.build",
                    description: "Swift build",
                    inputSchema: "{}"
                ),
                DirectToolDescriptor(
                    name: "web.search",
                    description: "Web search",
                    inputSchema: "{}"
                ),
                DirectToolDescriptor(
                    name: "web.fetch",
                    description: "Web fetch",
                    inputSchema: "{}"
                )
            ]
        )
        let rendered = TerminalChat.renderActiveTools(
            activeToolNames,
            items: items,
            selectedKeys: selectedKeys
        )

        #expect(rendered == "Active tools: Git (2), Swift (1), Web (2)\n")
        #expect(!rendered.contains("(0)"))
    }

    @Test
    func discoveredMCPDescriptorsAreRenderedInsideFeaturePackage() throws {
        let items = TerminalChat.toolSelectionItems(
            featureStatuses: [
                featureStatus(
                    id: "custom-design",
                    displayName: "Design",
                    description: "Design tools.",
                    source: .generated,
                    tools: ["design.Build"],
                    toolNamePrefixes: ["design."],
                    discoversToolsAtRuntime: true
                )
            ]
        )
        let designItem = try #require(items.first { $0.title == "Design" })
        let selectedKeys = try TerminalChat.parseToolSelection("design", items: items)
        let allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedKeys,
            items: items
        )
        let rendered = TerminalChat.renderActiveTools(
            Array(allowedToolNames),
            items: items,
            selectedKeys: selectedKeys
        )

        #expect(designItem.detail == "Design tools.")
        #expect(allowedToolNames.contains("design.Build"))
        #expect(rendered.contains("Design (1)"))
        #expect(!rendered.contains("design.Build"))
        #expect(rendered.hasPrefix("Active tools: Design (1)"))
    }
}
