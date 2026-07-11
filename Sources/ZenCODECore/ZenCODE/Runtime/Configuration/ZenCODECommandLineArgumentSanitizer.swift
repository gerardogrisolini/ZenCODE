//
//  ZenCODECommandLineArgumentSanitizer.swift
//  ZenCODE
//

import Foundation

public enum ZenCODECommandLineArgumentSanitizer {
    public static func sanitized(_ arguments: [String]) -> [String] {
        guard let executable = arguments.first else {
            return []
        }

        var result = [executable]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if isCocoaLaunchArgument(argument) {
                index += 1
                if index < arguments.count, !arguments[index].hasPrefix("-") {
                    index += 1
                }
                continue
            }

            result.append(argument)
            index += 1
        }

        return result
    }

    public static func containsCocoaLaunchArguments(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains(where: isCocoaLaunchArgument(_:))
    }

    private static func isCocoaLaunchArgument(_ argument: String) -> Bool {
        argument == "-NSDocumentRevisionsDebugMode"
            || argument == "-ApplePersistenceIgnoreState"
            || argument == "-NSQuitAlwaysKeepsWindows"
            || argument.hasPrefix("-NS")
            || argument.hasPrefix("-Apple")
    }
}
