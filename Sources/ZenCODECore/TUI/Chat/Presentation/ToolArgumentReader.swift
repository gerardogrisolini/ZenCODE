//
//  ToolArgumentReader.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Reads the arguments of a tool call the way the terminal's tool rows need
/// them: verbatim payloads, array-of-object payloads, and path-shaped metadata
/// that is neutralized before it can reach a rendered row.
enum ToolArgumentReader {
    /// Path-shaped metadata. Blank or whitespace-only values must fall through
    /// to the next alias key (and ultimately to the caller's fallback), and
    /// control characters must never reach a rendered metadata row or the
    /// language hint.
    static func metadataArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = rawStringArgument(arguments, keys: [key]) else {
                continue
            }
            if let sanitized = sanitizedMetadataText(value) {
                return sanitized
            }
        }
        return nil
    }

    /// Single neutralization point for every caller-controllable value rendered
    /// as metadata: titles, locations, change rows, patch targets and the
    /// language hint. Every control scalar — C0, DEL, C1 and the format
    /// characters that carry bidi/zero-width behavior — becomes a space, so no
    /// payload can emit ESC, CR, LF or a tab into a rendered metadata row.
    /// Returns `nil` for values that are blank once neutralized, so the caller
    /// falls through to the next alias or to its own fallback.
    static func sanitizedMetadataText(_ value: String) -> String? {
        // CRLF is one line ending rather than two controls, so it collapses to a
        // single space before the per-scalar neutralization below.
        let lineEndingNormalized = value.replacingOccurrences(of: "\r\n", with: " ")
        var sanitized = ""
        sanitized.reserveCapacity(lineEndingNormalized.count)
        for character in lineEndingNormalized {
            let isControl = character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            sanitized.append(isControl ? " " : character)
        }
        let normalized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Sanitized patch target. `patchDisplayTarget` derives its value from the
    /// patch body, which is fully caller-controlled, so it must not reach the
    /// change row or the language hint unneutralized.
    static func patchTargetPath(_ arguments: [String: Any]) -> String? {
        guard let target = ToolCallPresentation.patchDisplayTarget(from: arguments) else {
            return nil
        }
        return sanitizedMetadataText(target)
    }

    static func targetPath(_ arguments: [String: Any]) -> String? {
        metadataArgument(
            arguments,
            keys: [
                "file_path",
                "filePath",
                "file",
                "path",
                "directoryPath",
                "directory_path"
            ]
        )
    }

    /// Verbatim payload accessor. Source content is reproduced exactly: empty
    /// strings, whitespace-only edits and trailing newlines are all meaningful
    /// mutation payloads, so nothing is trimmed or skipped here.
    static func rawStringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
            if let value = arguments[key] as? JSONValue,
               let stringValue = value.stringValue {
                return stringValue
            }
        }
        return nil
    }

    static func arrayObjectArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [[String: Any]] {
        for key in keys {
            if let value = arguments[key] as? [[String: Any]] {
                return value
            }
            if let value = arguments[key] as? [Any] {
                return value.compactMap { $0 as? [String: Any] }
            }
            if let value = arguments[key] as? JSONValue,
               case let .array(items) = value {
                return items.compactMap { item in
                    guard case let .object(object) = item else {
                        return nil
                    }
                    return object.mapValues(\.jsonObject)
                }
            }
        }
        return []
    }
}
