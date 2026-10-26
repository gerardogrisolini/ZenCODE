//
//  PatchLines.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/10/26.
//

import Foundation

/// The line model shared by every `local.applyPatch` parser and by the text of
/// the files it patches: lines end at the UTF-8 byte `0x0A` and keep any `\r`
/// that precedes it, so line content is byte-exact.
///
/// `String.components(separatedBy: "\n")` is not a stable foundation for this:
/// swift-corelibs-foundation treats the `\r\n` grapheme as a single `Character`
/// and never splits it, so a CRLF payload stays one line on Linux, while
/// `String.hasSuffix("\n")` is false for a string ending in `\r\n`. A
/// `Character`-based `split(separator: "\n")` never splits CRLF on any platform.
/// Working on UTF-8 bytes gives the same result everywhere.
enum PatchLines {
    /// Splits `text` at every `\n` byte, keeping empty subsequences and any `\r`
    /// inside the elements. An empty string yields `[""]`, and a string ending in
    /// a line feed yields a final empty element, as
    /// `components(separatedBy: "\n")` does on macOS.
    ///
    /// `join(separator: "\n")` of the result restores `text` byte for byte.
    static func split(_ text: String) -> [String] {
        text.utf8
            .split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
    }

    /// Returns `line` without one trailing `\r`, for the structural recognition
    /// of markers (`*** End Patch`, `--- `/`+++ ` headers, `\ No newline at end
    /// of file`) that must tolerate CRLF payloads. Line content is never passed
    /// through this: a CRLF patch has to match a CRLF file byte for byte.
    static func withoutTrailingCarriageReturn(_ line: String) -> String {
        guard line.utf8.last == 0x0D else { return line }
        return String(decoding: line.utf8.dropLast(), as: UTF8.self)
    }

    /// Whether `text` ends with a line feed. Unlike `String.hasSuffix("\n")`,
    /// this is true for a string ending in `\r\n` on every platform.
    static func endsWithLineFeed(_ text: String) -> Bool {
        text.utf8.last == 0x0A
    }
}
