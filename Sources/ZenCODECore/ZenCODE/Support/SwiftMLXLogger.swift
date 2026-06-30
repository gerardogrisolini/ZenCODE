//
//  SwiftMLXLogger.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public enum SwiftMLXLogLevel: Int, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public static func < (lhs: SwiftMLXLogLevel, rhs: SwiftMLXLogLevel) -> Bool {
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

public enum SwiftMLXLogCategory: String, Sendable {
    case assistantBackend = "MLXAssistantBackendService"
    case applicationDelegate = "ZenCODEApplicationDelegate"
    case cloudChatWorker = "MLXCloudChatWorker"
    case cloudKit = "ZenCODECloudKit"
    case contentViewModel = "ContentViewModel"
    case installedModelCatalog = "MLXInstalledModelCatalogService"
    case memory = "MLXMemoryService"
    case mlxViewActions = "MLXViewActions"
    case remoteModelCatalogClient = "RemoteModelCatalogClient"
    case remoteNotification = "ZenCODERemoteNotification"
    case remotePrompt = "MLXRemotePrompt"
    case sessionService = "MLXSessionService"
    case bashToolExecutor = "BashToolExecutor"
    case mcpClient = "MCPClient"
    case taskListSync = "TaskListSync"
    case taskExecutionCoordinator = "MLXTaskExecutionCoordinator"
    case taskExecutionEngine = "MLXTaskExecutionEngineSupport"
    case taskLifecycle = "MLXTaskLifecycleService"
    case toolBackendResolver = "ToolBackendResolver"
    case toolDescriptor = "ToolDescriptor"
    case turnFileChangeTracker = "TurnFileChangeTracker"
    case turnGeneration = "MLXTurnGenerationService"
    case userInput = "MLXUserInputService"
    case viewModel = "MLXViewModel"
    case viewModelRuntime = "MLXViewModelRuntimeService"
    case xcodeToolExecutor = "XcodeToolExecutor"
    case conversationHistory = "MLXConversationHistorySupport"
}

public enum SwiftMLXLogger {
    public static func debug(
        _ category: SwiftMLXLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.debug, category, message)
    }

    public static func info(
        _ category: SwiftMLXLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.info, category, message)
    }

    public static func warning(
        _ category: SwiftMLXLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.warning, category, message)
    }

    public static func error(
        _ category: SwiftMLXLogCategory,
        _ message: @autoclosure () -> String
    ) {
        log(.error, category, message)
    }

    public static func log(
        _ level: SwiftMLXLogLevel,
        _ category: SwiftMLXLogCategory,
        _ message: () -> String
    ) {
        _ = level
        _ = category
        _ = message
    }

    public static func formattedMessage(
        level: SwiftMLXLogLevel,
        category: SwiftMLXLogCategory,
        message: String
    ) -> String {
        "[\(category.rawValue)][\(level.label)] \(messageBody(category: category, message: message))"
    }

    private static func messageBody(
        category: SwiftMLXLogCategory,
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
