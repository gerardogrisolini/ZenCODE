import ToolCore
import Foundation
import FeatureKit

public enum WebToolsFeatureRunner {
    public static func run() async {
        await FeatureRunner.run([
            AnyFeatureTool(WebSearchTool()),
            AnyFeatureTool(WebFetchTool())
        ])
    }
}

enum WebToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case invalidURL(String)
    case unsupportedScheme(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .invalidURL(value):
            return "Invalid URL: \(value)"
        case let .unsupportedScheme(scheme):
            return "Unsupported URL scheme '\(scheme)'. Only http and https are supported."
        case let .permissionDenied(message):
            return message
        }
    }
}

extension WebSearchTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Web", action: "Search", kind: .search, targetKeyPaths: ["query"])
    }
}

extension WebFetchTool {
    static var presentation: ToolPresentationDefinition {
        .standard(title: "Web page", action: "Fetch", kind: .read, targetKeyPaths: ["url"], targetFormat: .url)
    }
}
