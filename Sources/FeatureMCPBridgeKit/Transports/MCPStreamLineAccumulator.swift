//
//  MCPStreamLineAccumulator.swift
//  ZenCODE
//

import Foundation
import Synchronization

#if os(macOS)
/// Splits pumped bytes into newline-terminated lines for line-oriented local MCP
/// streams. Peers are untrusted, so only a bounded tail is retained when a line
/// never terminates. Kept separate from the pump so byte transport and line
/// framing stay independently reviewable.
final class MCPStreamLineAccumulator: Sendable {
    private let byteLimit: Int
    private let storage = Mutex(Data())

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    /// Appends `chunk` and returns every complete UTF-8 line it made available.
    func lines(appending chunk: Data) -> [String] {
        storage.withLock { buffer in
            buffer.append(chunk)
            if buffer.count > byteLimit {
                buffer = Data(buffer.suffix(byteLimit))
            }

            var lines: [String] = []
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex ..< newlineIndex)
                buffer.removeSubrange(buffer.startIndex ... newlineIndex)
                if let line = String(data: lineData, encoding: .utf8) {
                    lines.append(line)
                }
            }
            return lines
        }
    }
}
#endif
