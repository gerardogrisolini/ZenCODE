//
//  MCPClient+TransportLogging.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

#if os(macOS)
/// Local transport logging hooks. Kept trivial and redaction-neutral: nothing
/// here formats secrets, and buffered previews are emitted only when the frame
/// snapshot actually changes.
extension MCPClient {
    func importantLog(_ message: String) {
        log(message)
    }

    func logBufferedPrefixIfNeeded() {
        let prefixData = buffer.prefix(200)
        let utf8Preview = String(data: prefixData, encoding: .utf8) ?? "<non-utf8>"
        let escapedPreview = utf8Preview
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let hexPreview = prefixData.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
        let snapshot = "size=\(buffer.count) utf8=\"\(escapedPreview)\" hex=\(hexPreview)"

        guard snapshot != lastBufferedPrefixSnapshot else {
            return
        }

        lastBufferedPrefixSnapshot = snapshot
        log("buffered stdout prefix \(snapshot)")
    }

    func log(_ message: String) {
        _ = message
    }
}
#endif
