//
//  RemoteGenerationClient+TurnText.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation

extension RemoteGenerationClient {
    /// Appends the text of one tool round to the turn-level accumulated text.
    ///
    /// The text of consecutive rounds is joined into `DirectAgentResponse.text`.
    /// Without a separator the last sentence of a round and the beginning of the
    /// next one end up on the same line (`…transcript.## Next`), which breaks
    /// line-based parsers such as the `/plan` heading detection. A single `\n` is
    /// inserted unless one of the two sides already provides a line break.
    /// Streamed `.content` events and the per-round assistant messages kept in
    /// the session history are not affected.
    static func appendRoundText(_ roundText: String, to accumulatedText: inout String) {
        guard !roundText.isEmpty else {
            return
        }
        guard let last = accumulatedText.last, let first = roundText.first else {
            accumulatedText.append(roundText)
            return
        }
        if last.isNewline || first.isNewline {
            accumulatedText.append(roundText)
        } else {
            accumulatedText.append("\n")
            accumulatedText.append(roundText)
        }
    }
}
