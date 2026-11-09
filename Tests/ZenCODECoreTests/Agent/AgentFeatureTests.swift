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
    func toolSelectionCatalogHidesDisabledFeaturePackages() {
        let items = ChatSessionController.toolSelectionItems(
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
    func activeToolRenderingCountsResolvedRuntimeDescriptors() throws {
        let items = ChatSessionController.toolSelectionItems(
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
        let selectedKeys = try TerminalToolSelectionCatalog.parseSelection(
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
}
