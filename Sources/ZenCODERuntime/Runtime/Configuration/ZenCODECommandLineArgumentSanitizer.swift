//
//  ZenCODECommandLineArgumentSanitizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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

    private static func isCocoaLaunchArgument(_ argument: String) -> Bool {
        argument == "-NSDocumentRevisionsDebugMode"
            || argument == "-ApplePersistenceIgnoreState"
            || argument == "-NSQuitAlwaysKeepsWindows"
            || argument.hasPrefix("-NS")
            || argument.hasPrefix("-Apple")
    }
}
