//
//  LocalToolsSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FeatureKit


public enum LocalFeatureTools {
    public static func fileTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(LocalPwdTool()),
            AnyFeatureTool(LocalListDirectoryTool()),
            AnyFeatureTool(LocalReadFileTool()),
            AnyFeatureTool(LocalReadFilesTool()),
            AnyFeatureTool(LocalInspectFileTool()),
            AnyFeatureTool(LocalWriteFileTool()),
            AnyFeatureTool(LocalReplaceTool()),
            AnyFeatureTool(LocalEditFileTool()),
            AnyFeatureTool(LocalMultiEditTool()),
            AnyFeatureTool(LocalAppendTool()),
            AnyFeatureTool(LocalMakeDirectoryTool()),
            AnyFeatureTool(LocalDeleteTool()),
            AnyFeatureTool(LocalMoveTool()),
            AnyFeatureTool(LocalApplyPatchTool())
        ]
    }

    public static func searchTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(SearchGlobTool()),
            AnyFeatureTool(SearchGrepTool()),
            AnyFeatureTool(SearchLocateTool())
        ]
    }

    public static func textTools() -> [AnyFeatureTool] {
        [
            AnyFeatureTool(TextHeadTool()),
            AnyFeatureTool(TextTailTool()),
            AnyFeatureTool(TextSortTool()),
            AnyFeatureTool(TextWordCountTool())
        ]
    }
}

enum LocalToolsFeatureError: LocalizedError {
    case missingArgument(String)
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .missingArgument(argument):
            return "Missing required argument: \(argument)"
        case let .permissionDenied(message):
            return message
        }
    }
}
