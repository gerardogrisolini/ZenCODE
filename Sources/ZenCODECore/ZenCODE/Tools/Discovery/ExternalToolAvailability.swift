//
//  ExternalToolAvailability.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 09/06/26.
//

import Foundation

public enum ExternalToolAvailability {
    public static func resolvedAllowedToolNames(
        _ allowedToolNames: Set<String>?
    ) -> Set<String>? {
        return allowedToolNames
    }

    public static func resolvedAllowedToolNames(
        _ allowedToolNames: Set<String>,
        unavailableToolPrefixes: Set<String>
    ) -> Set<String> {
        guard !allowedToolNames.isEmpty,
              !unavailableToolPrefixes.isEmpty else {
            return allowedToolNames
        }

        return Set(
            allowedToolNames.filter { allowedToolName in
                !unavailableToolPrefixes.contains { prefix in
                    allowedToolName == prefix || allowedToolName.hasPrefix(prefix)
                }
            }
        )
    }

    public static func discoverableToolPrefixes(
        _ toolPrefixes: Set<String>,
        xcodeIsRunning: Bool = MCPServerConfiguration.isXcodeRunning()
    ) -> Set<String> {
        resolvedAllowedToolNames(
            toolPrefixes,
            unavailableToolPrefixes: unavailableToolPrefixes(
                xcodeIsRunning: xcodeIsRunning
            )
        )
    }

    private static func unavailableToolPrefixes(
        xcodeIsRunning: Bool
    ) -> Set<String> {
        xcodeIsRunning ? [] : ["xcode.", "Xcode"]
    }
}
