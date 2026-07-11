//
//  FeatureProcessProtocol.swift
//  ZenCODE
//

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The canonical command line protocol implemented by feature executables.
///
/// Feature hosts invoke executables with either `--list-tools` or `--invoke`.
/// Keeping the argument parsing and JSON envelopes here ensures FeatureKit
/// runners and generated FeatureKit-based scaffolds produce the same wire
/// format.
public enum FeatureProcessProtocol {
    public enum Command: Sendable {
        case listTools
        case invoke(toolName: String, workingDirectory: URL?)
        case usage
    }

    /// Parses arguments after the executable name.
    public static func parse(arguments: [String]) -> Command {
        guard let first = arguments.first else {
            return .usage
        }

        switch first {
        case "--list-tools":
            return .listTools
        case "--invoke":
            guard arguments.count >= 2 else {
                return .usage
            }
            return .invoke(
                toolName: arguments[1],
                workingDirectory: optionValue("--working-directory", in: arguments).map {
                    URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath)
                }
            )
        default:
            return .usage
        }
    }

    /// Encodes values using the stable formatting required by the feature
    /// process protocol.
    public static func renderJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Writes a JSON response followed by its protocol-required newline.
    public static func emitJSON<T: Encodable>(_ value: T) throws {
        FileHandle.standardOutput.write(try renderJSON(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// Writes the successful invocation envelope without re-encoding its JSON
    /// output. This preserves arbitrary `Encodable` tool output exactly.
    public static func emitSuccess(outputData: Data) {
        FileHandle.standardOutput.write(Data(#"{"ok":true,"output":"#.utf8))
        FileHandle.standardOutput.write(outputData)
        FileHandle.standardOutput.write(Data("}\n".utf8))
    }

    public static let usageText = """
    Usage:
      feature-binary --list-tools
      feature-binary --invoke <tool-name> [--working-directory <path>]
    """

    public static func terminate(code: Int32) -> Never {
        #if canImport(Darwin) || canImport(Glibc)
        exit(code)
        #else
        fatalError("Feature process terminated with code \(code).")
        #endif
    }

    private static func optionValue(_ option: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: option),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}
