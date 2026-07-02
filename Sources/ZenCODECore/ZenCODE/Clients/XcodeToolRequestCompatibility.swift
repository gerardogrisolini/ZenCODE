//
//  XcodeToolRequestCompatibility.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public nonisolated enum XcodeToolRequestCompatibility {
    private static let toolsRequiringTabIdentifier: Set<String> = [
        "BuildProject",
        "ExecuteSnippet",
        "GetBuildLog",
        "GetTestList",
        "RenderPreview",
        "RunAllTests",
        "RunSomeTests",
        "XcodeGlob",
        "XcodeGrep",
        "XcodeLS",
        "XcodeListNavigatorIssues",
        "XcodeMakeDir",
        "XcodeMV",
        "XcodeRM",
        "XcodeRead",
        "XcodeRefreshCodeIssuesInFile",
        "XcodeUpdate",
        "XcodeWrite"
    ]

    private static let tabIdentifierSourceKeys = [
        "tabIdentifier",
        "tab_identifier",
        "tabidentifier",
        "tabId",
        "tab_id",
        "tabid",
        "windowTabIdentifier",
        "window_tab_identifier",
        "windowtabidentifier"
    ]

    private static let aliases: [String: String] = [
        "xcodeupdate": "XcodeUpdate",
        "xcode_update": "XcodeUpdate",
        "xcode.update": "XcodeUpdate",
        "xcodeedit": "XcodeUpdate",
        "xcode.edit": "XcodeUpdate",
        "xcodewrite": "XcodeWrite",
        "xcode_write": "XcodeWrite",
        "xcode.write": "XcodeWrite",
        "xcoderead": "XcodeRead",
        "xcode_read": "XcodeRead",
        "xcode.read": "XcodeRead",
        "xcodeglob": "XcodeGlob",
        "xcode_glob": "XcodeGlob",
        "xcode.glob": "XcodeGlob",
        "xcodegrep": "XcodeGrep",
        "xcode_grep": "XcodeGrep",
        "xcode.grep": "XcodeGrep",
        "xcodels": "XcodeLS",
        "xcode_ls": "XcodeLS",
        "xcode.ls": "XcodeLS",
        "xcodemv": "XcodeMV",
        "xcode_mv": "XcodeMV",
        "xcode.mv": "XcodeMV",
        "xcodemkdir": "XcodeMakeDir",
        "xcode_mkdir": "XcodeMakeDir",
        "xcode.mkdir": "XcodeMakeDir",
        "xcoderm": "XcodeRM",
        "xcode_rm": "XcodeRM",
        "xcode.rm": "XcodeRM",
        "buildproject": "BuildProject",
        "build_project": "BuildProject",
        "build": "BuildProject",
        "documentationsearch": "DocumentationSearch",
        "documentation_search": "DocumentationSearch",
        "docsearch": "DocumentationSearch",
        "executesnippet": "ExecuteSnippet",
        "execute_snippet": "ExecuteSnippet",
        "snippet": "ExecuteSnippet",
        "getbuildlog": "GetBuildLog",
        "get_build_log": "GetBuildLog",
        "buildlog": "GetBuildLog",
        "gettestlist": "GetTestList",
        "get_test_list": "GetTestList",
        "testlist": "GetTestList",
        "renderpreview": "RenderPreview",
        "render_preview": "RenderPreview",
        "preview": "RenderPreview",
        "runalltests": "RunAllTests",
        "run_all_tests": "RunAllTests",
        "runsometests": "RunSomeTests",
        "run_some_tests": "RunSomeTests",
        "xcodelistnavigatorissues": "XcodeListNavigatorIssues",
        "xcoderefreshcodeissuesinfile": "XcodeRefreshCodeIssuesInFile"
    ]

    public static func normalize(_ request: ToolRequest) -> ToolRequest? {
        let lowerName = request.name.lowercased()
        if let canonicalName = aliases[lowerName] {
            return ToolRequest(
                name: canonicalName,
                arguments: normalizedArguments(request.arguments, for: canonicalName)
            )
        }
        if request.name.hasPrefix("Xcode") || request.name == "BuildProject"
            || request.name == "DocumentationSearch" || request.name == "ExecuteSnippet"
            || request.name == "GetBuildLog" || request.name == "GetTestList"
            || request.name == "RenderPreview" || request.name == "RunAllTests"
            || request.name == "RunSomeTests" {
            return ToolRequest(
                name: request.name,
                arguments: normalizedArguments(request.arguments, for: request.name)
            )
        }
        return nil
    }

    public static func requiresTabIdentifier(_ toolName: String) -> Bool {
        toolsRequiringTabIdentifier.contains(toolName)
    }

    private static func normalizedArguments(
        _ arguments: [String: JSONValue],
        for toolName: String
    ) -> [String: JSONValue] {
        var normalized: [String: JSONValue] = [:]

        if toolsRequiringTabIdentifier.contains(toolName) {
            assignString(tabIdentifierSourceKeys, from: arguments, to: "tabIdentifier", in: &normalized)
        }

        switch toolName {
        case "XcodeUpdate":
            assignPathString(["filePath", "file_path", "path"], from: arguments, to: "filePath", in: &normalized)
            assignXcodeSnippetString(["oldString", "old_string"], from: arguments, to: "oldString", in: &normalized)
            assignXcodeSnippetString(["newString", "new_string"], from: arguments, to: "newString", in: &normalized)
            assignBool(["replaceAll", "replace_all"], from: arguments, to: "replaceAll", in: &normalized)
        case "XcodeWrite":
            assignPathString(["filePath", "file_path", "path"], from: arguments, to: "filePath", in: &normalized)
            assignString(["content", "text"], from: arguments, to: "content", in: &normalized)
        case "XcodeRead":
            assignPathString(["filePath", "file_path", "path"], from: arguments, to: "filePath", in: &normalized)
            assignNumber(["offset"], from: arguments, to: "offset", in: &normalized)
            assignNumber(["limit"], from: arguments, to: "limit", in: &normalized)
        case "XcodeGrep":
            assignString(["pattern"], from: arguments, to: "pattern", in: &normalized)
            assignPathString(["path"], from: arguments, to: "path", in: &normalized)
            assignString(["glob"], from: arguments, to: "glob", in: &normalized)
            assignString(["type"], from: arguments, to: "type", in: &normalized)
            assignBool(["showLineNumbers", "show_line_numbers"], from: arguments, to: "showLineNumbers", in: &normalized)
            assignString(["outputMode", "output_mode"], from: arguments, to: "outputMode", in: &normalized)
            assignNumber(["headLimit", "head_limit", "maxResults", "max_results"], from: arguments, to: "headLimit", in: &normalized)
            assignBool(["ignoreCase", "ignore_case"], from: arguments, to: "ignoreCase", in: &normalized)
            assignNumber(["linesContext", "lines_context", "context"], from: arguments, to: "linesContext", in: &normalized)
            assignNumber(["linesBefore", "lines_before"], from: arguments, to: "linesBefore", in: &normalized)
            assignNumber(["linesAfter", "lines_after"], from: arguments, to: "linesAfter", in: &normalized)
            assignBool(["multiline"], from: arguments, to: "multiline", in: &normalized)
        case "XcodeGlob":
            assignString(["pattern"], from: arguments, to: "pattern", in: &normalized)
            assignPathString(["path"], from: arguments, to: "path", in: &normalized)
        case "XcodeLS":
            assignPathString(["path"], from: arguments, to: "path", in: &normalized)
            assignBool(["recursive"], from: arguments, to: "recursive", in: &normalized)
            assignStringArray(["ignore"], from: arguments, to: "ignore", in: &normalized)
        case "XcodeMV":
            assignPathString(["sourcePath", "source_path", "from"], from: arguments, to: "sourcePath", in: &normalized)
            assignPathString(["destinationPath", "destination_path", "to"], from: arguments, to: "destinationPath", in: &normalized)
            assignString(["operation"], from: arguments, to: "operation", in: &normalized)
            assignBool(["overwriteExisting", "overwrite_existing"], from: arguments, to: "overwriteExisting", in: &normalized)
        case "XcodeMakeDir":
            assignPathString(["directoryPath", "directory_path", "path"], from: arguments, to: "directoryPath", in: &normalized)
        case "XcodeRM":
            assignPathString(["path"], from: arguments, to: "path", in: &normalized)
            assignBool(["recursive"], from: arguments, to: "recursive", in: &normalized)
            assignBool(["deleteFiles", "delete_files"], from: arguments, to: "deleteFiles", in: &normalized)
        case "XcodeRefreshCodeIssuesInFile":
            assignPathString(["filePath", "file_path", "path"], from: arguments, to: "filePath", in: &normalized)
        case "XcodeListNavigatorIssues":
            assignString(["severity"], from: arguments, to: "severity", in: &normalized)
            assignString(["glob"], from: arguments, to: "glob", in: &normalized)
            assignString(["pattern"], from: arguments, to: "pattern", in: &normalized)
        case "DocumentationSearch":
            assignString(["query"], from: arguments, to: "query", in: &normalized)
            assignStringArray(["frameworks"], from: arguments, to: "frameworks", in: &normalized)
        case "ExecuteSnippet":
            assignString(["codeSnippet", "code_snippet", "code", "snippet"], from: arguments, to: "codeSnippet", in: &normalized)
            assignString(["purpose", "description", "summary"], from: arguments, to: "purpose", in: &normalized)
            assignPathString(["sourceFilePath", "source_file_path", "sourcePath", "source_path", "filePath", "file_path", "path"], from: arguments, to: "sourceFilePath", in: &normalized)
            assignNumber(["timeout", "timeoutSeconds", "timeout_seconds"], from: arguments, to: "timeout", in: &normalized)
        case "GetBuildLog":
            assignString(["severity"], from: arguments, to: "severity", in: &normalized)
            assignString(["pattern"], from: arguments, to: "pattern", in: &normalized)
            assignString(["glob"], from: arguments, to: "glob", in: &normalized)
        case "RenderPreview":
            assignPathString(["sourceFilePath", "source_file_path", "sourcePath", "source_path", "filePath", "file_path", "path"], from: arguments, to: "sourceFilePath", in: &normalized)
            assignNumber(["previewDefinitionIndexInFile", "preview_definition_index_in_file", "previewDefinitionIndex", "preview_definition_index", "previewIndex", "preview_index", "index"], from: arguments, to: "previewDefinitionIndexInFile", in: &normalized)
            assignNumber(["timeout", "timeoutSeconds", "timeout_seconds"], from: arguments, to: "timeout", in: &normalized)
        case "RunSomeTests":
            assignNormalizedXcodeTestSpecifiers(
                ["tests", "testCases", "test_cases", "testSpecifiers", "test_specifiers", "specifiers"],
                from: arguments,
                to: "tests",
                in: &normalized
            )
        default:
            normalized = arguments
        }

        return normalized
    }
}
