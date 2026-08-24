//
//  ToolExecutionLogTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct ToolExecutionLogTests {
    @Test
    func successfulEntryContainsExecutionMetadataAndRedactedArguments() throws {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz"
        let call = DirectAgentToolCall(
            id: "call-1",
            name: "local.exec",
            argumentsObject: [
                "command": "echo ok",
                "password": "plain-secret",
                "nested": ["api_key": secret]
            ],
            argumentsJSON: #"{"command":"echo ok","password":"plain-secret","nested":{"api_key":"sk-abcdefghijklmnopqrstuvwxyz"}}"#
        )
        let context = ToolExecutionContext(
            agentID: "developer-id",
            agentName: "Developer",
            modelID: "provider:model-1"
        )

        let entry = ToolExecutionLog.makeEntry(
            context: context,
            sessionID: "session-1",
            toolCall: call,
            workingDirectory: URL(fileURLWithPath: "/tmp/workspace"),
            status: .completed,
            summary: "command completed",
            duration: .milliseconds(125),
            error: nil
        )

        #expect(entry.event == "tool_execution")
        #expect(entry.tool == "local.exec")
        #expect(entry.toolCallID == "call-1")
        #expect(entry.agentID == "developer-id")
        #expect(entry.agentName == "Developer")
        #expect(entry.model == "provider:model-1")
        #expect(!entry.isSubAgent)
        #expect(entry.sessionID == "session-1")
        #expect(entry.workingDirectory == "/tmp/workspace")
        #expect(entry.durationMilliseconds == 125)
        #expect(entry.status == "completed")
        #expect(entry.summary == "command completed")
        #expect(entry.error == nil)

        let message = ToolExecutionLog.encodedMessage(for: entry)
        #expect(message.contains(#""command":"echo ok""#))
        #expect(message.contains(ZenSecretRedactor.placeholder))
        #expect(!message.contains("plain-secret"))
        #expect(!message.contains(secret))
        let decoded = try JSONDecoder().decode(
            ToolExecutionLogEntry.self,
            from: Data(message.utf8)
        )
        #expect(decoded == entry)
    }

    @Test
    func failedEntryIncludesTypedCauseAndUnderlyingError() {
        let secret = "sk-abcdefghijklmnopqrstuvwxyz"
        let underlying = NSError(
            domain: "ToolTransport",
            code: 41,
            userInfo: [NSLocalizedDescriptionKey: "socket rejected token=\(secret)"]
        )
        let failure = NSError(
            domain: "ToolExecution",
            code: 9,
            userInfo: [
                NSLocalizedDescriptionKey: "Unable to execute tool",
                NSLocalizedFailureReasonErrorKey: "The child process exited before replying.",
                NSLocalizedRecoverySuggestionErrorKey: "Check the executable and retry.",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let entry = ToolExecutionLog.makeEntry(
            context: ToolExecutionContext(agentName: "Developer", modelID: "model-1"),
            sessionID: "session-1",
            toolCall: toolCall(),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .failed,
            summary: "Tool error: Unable to execute tool",
            duration: .milliseconds(7),
            error: failure
        )

        #expect(entry.status == "failed")
        #expect(entry.durationMilliseconds == 7)
        #expect(entry.error?.domain == "ToolExecution")
        #expect(entry.error?.code == 9)
        #expect(entry.error?.message == "Unable to execute tool")
        #expect(entry.error?.failureReason == "The child process exited before replying.")
        #expect(entry.error?.recoverySuggestion == "Check the executable and retry.")
        #expect(entry.error?.underlyingErrors.count == 1)
        #expect(entry.error?.underlyingErrors.first?.domain == "ToolTransport")
        let message = ToolExecutionLog.encodedMessage(for: entry)
        #expect(message.contains("ToolTransport"))
        #expect(message.contains(ZenSecretRedactor.placeholder))
        #expect(!message.contains(secret))
    }

    @Test
    func subAgentEntryKeepsIdentityAndOmitsUnavailableDuration() {
        let context = ToolExecutionContext(
            agentID: "child-42",
            agentName: "reviewer",
            modelID: "model-child",
            isSubAgent: true
        )
        let entry = ToolExecutionLog.makeEntry(
            context: context,
            sessionID: "child-42_session",
            toolCall: toolCall(),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            status: .completed,
            summary: "ok",
            duration: nil,
            error: nil
        )

        #expect(entry.agentID == "child-42")
        #expect(entry.agentName == "reviewer")
        #expect(entry.model == "model-child")
        #expect(entry.isSubAgent)
        #expect(entry.durationMilliseconds == nil)
        #expect(!ToolExecutionLog.encodedMessage(for: entry).contains("durationMilliseconds"))
    }

    @Test
    func runtimeConfigurationCarriesCoordinatorIdentity() {
        let configuration = AgentCoreSessionConfigurationBuilder(
            sessionID: "session-1",
            modelID: "model-main",
            agentID: "developer-id",
            agentName: "Developer",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            systemPrompt: "prompt",
            cacheKey: "cache"
        )
        .makeConfiguration()

        #expect(configuration.agentID == "developer-id")
        #expect(configuration.agentName == "Developer")
        #expect(configuration.runtimeConfiguration.agentID == "developer-id")
        #expect(configuration.runtimeConfiguration.agentName == "Developer")
        #expect(configuration.runtimeConfiguration.modelID == "model-main")
    }

    @Test
    func subAgentBackendContextReplacesCoordinatorIdentityEvenWhenModelIsLocked() {
        let parent = AgentRuntimeConfiguration(
            modelID: "parent-model",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            maxToolRounds: 4,
            verboseLogging: false,
            locksModelToSession: true,
            toolAuthorizationHandler: nil,
            agentID: "coordinator-id",
            agentName: "Developer"
        )
        let childContext = DirectSubAgentRuntime.BackendContext(
            requestedName: "Reviewer 1",
            requestedRole: "reviewer",
            profile: nil,
            sharedChatSenderID: "child-id",
            sharedChatRoomID: "root-session"
        )

        let child = parent.applyingSubAgentBackendContext(childContext)

        #expect(child.agentID == "child-id")
        #expect(child.agentName == "Reviewer 1")
        #expect(child.modelID == "parent-model")
    }

    @Test
    func executionContextResolvesCoordinatorAndSubAgentFallbackIdentities() {
        let coordinator = ToolExecutionContext().resolved(fallbackAgentID: nil)
        let child = ToolExecutionContext(modelID: "child-model")
            .resolved(fallbackAgentID: "child-id")

        #expect(coordinator.agentID == "coordinator")
        #expect(coordinator.agentName == "coordinator")
        #expect(!coordinator.isSubAgent)
        #expect(child.agentID == "child-id")
        #expect(child.isSubAgent)
        #expect(child.modelID == "child-model")
    }

    @Test
    func toolsLogsRequestRequiresExactlyOneArgumentToken() {
        #expect(TerminalChat.isToolLogsRequest("logs"))
        #expect(TerminalChat.isToolLogsRequest("  LOGS\t"))
        #expect(!TerminalChat.isToolLogsRequest(""))
        #expect(!TerminalChat.isToolLogsRequest("logs extra"))
        #expect(!TerminalChat.isToolLogsRequest("log"))
    }

    @Test
    func toolsUsageAndHelpDocumentTheSystemLogViewer() {
        #expect(TerminalChat.renderToolSelectionUsage().contains("logs"))
        let descriptor = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).first { $0.command == "/tools" }
        #expect(descriptor?.help.contains("system log viewer") == true)
        let suggestions = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/tools")
        #expect(suggestions.contains {
            $0 == TerminalCommandSuggestion(command: "logs", summary: "open the system log viewer")
        })
    }

    @Test
    func systemLogViewerBuildsNativePlatformCommand() throws {
        let executablePaths: Set<String> = [
            "/usr/bin/open",
            "/usr/bin/gtk-launch",
            "/mnt/c/Windows/System32/cmd.exe"
        ]
        let command = try SystemLogViewerLauncher.command(
            isExecutableFile: executablePaths.contains,
            environment: ["WSL_DISTRO_NAME": "Ubuntu"]
        )

        #if os(macOS)
        #expect(command.executableURL.path == "/usr/bin/open")
        #expect(command.arguments == ["-b", "com.apple.Console"])
        #elseif os(Windows)
        #expect(command.arguments == ["/c", "start", "", "eventvwr.msc"])
        #else
        #expect(command.executableURL.path == "/usr/bin/gtk-launch")
        #expect(command.arguments == ["org.gnome.Logs"])
        #endif
    }

    @Test
    func systemLogViewerFailsWhenNoNativeViewerExists() {
        #if os(Windows)
        #expect(throws: Never.self) {
            _ = try SystemLogViewerLauncher.command(isExecutableFile: { _ in false })
        }
        #else
        #expect(throws: SystemLogViewerLauncher.LaunchError.unavailable) {
            _ = try SystemLogViewerLauncher.command(
                isExecutableFile: { _ in false },
                environment: [:]
            )
        }
        #endif
    }

    @Test
    func systemLogViewerErrorsExplainTheFailure() {
        #expect(
            SystemLogViewerLauncher.LaunchError.unavailable.errorDescription
                == "No system log viewer is available."
        )
        #expect(
            SystemLogViewerLauncher.LaunchError.timedOut.errorDescription
                == "The system log viewer did not open before the timeout."
        )
        #expect(
            SystemLogViewerLauncher.LaunchError.failed(3).errorDescription
                == "The system log viewer failed with exit code 3."
        )
    }

    private func toolCall() -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "call-1",
            name: "local.exec",
            argumentsObject: ["command": "echo ok"],
            argumentsJSON: #"{"command":"echo ok"}"#
        )
    }
}
