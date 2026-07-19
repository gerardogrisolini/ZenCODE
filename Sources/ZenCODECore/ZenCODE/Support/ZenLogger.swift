//
//  ZenLogger.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum ZenLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: ZenLogLevel, rhs: ZenLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .debug:
            return "DEBUG"
        case .info:
            return "INFO"
        case .warning:
            return "WARNING"
        case .error:
            return "ERROR"
        }
    }
}

public enum ZenLogCategory: String, Sendable {
    case assistantBackend = "AssistantBackendService"
    case applicationDelegate = "ZenCODEApplicationDelegate"
    case cloudChatWorker = "CloudChatWorker"
    case cloudKit = "ZenCODECloudKit"
    case contentViewModel = "ContentViewModel"
    case installedModelCatalog = "InstalledModelCatalogService"
    case memory = "MemoryService"
    case viewActions = "ViewActions"
    case remoteModelCatalogClient = "RemoteModelCatalogClient"
    case remoteNotification = "ZenCODERemoteNotification"
    case remotePrompt = "RemotePrompt"
    case sessionService = "SessionService"
    case bashToolExecutor = "BashToolExecutor"
    case mcpClient = "MCPClient"
    case taskListSync = "TaskListSync"
    case taskExecutionCoordinator = "TaskExecutionCoordinator"
    case taskExecutionEngine = "TaskExecutionEngineSupport"
    case taskLifecycle = "TaskLifecycleService"
    case toolBackendResolver = "ToolBackendResolver"
    case toolDescriptor = "ToolDescriptor"
    case turnFileChangeTracker = "TurnFileChangeTracker"
    case turnGeneration = "TurnGenerationService"
    case userInput = "UserInputService"
    case viewModel = "ViewModel"
    case viewModelRuntime = "ViewModelRuntimeService"
    case xcodeToolExecutor = "XcodeToolExecutor"
    case conversationHistory = "ConversationHistorySupport"
}

public enum ZenLogger {
    public static func debug(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.debug, category, message)
    }

    public static func info(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.info, category, message)
    }

    public static func warning(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.warning, category, message)
    }

    public static func error(
        _ category: ZenLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.error, category, message)
    }

    public static func log(
        _ level: ZenLogLevel,
        _ category: ZenLogCategory,
        _ message: () -> String
    ) {
        _ = level
        _ = category
        _ = message
    }

    public static func formattedMessage(
        level: ZenLogLevel,
        category: ZenLogCategory,
        message: String
    ) -> String {
        "[\(category.rawValue)][\(level.label)] \(messageBody(category: category, message: message))"
    }

    private static func messageBody(
        category: ZenLogCategory,
        message: String
    ) -> String {
        let normalizedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let categoryPrefix = "[\(category.rawValue)]"
        if normalizedMessage.hasPrefix(categoryPrefix) {
            return normalizedMessage
                .dropFirst(categoryPrefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalizedMessage
    }
}
