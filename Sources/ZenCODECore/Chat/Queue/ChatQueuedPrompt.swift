//
//  ChatQueuedPrompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

/// How a queued prompt re-enters the session when its turn comes.
///
/// Not generic over the origin: the mode describes what the text is, never who
/// sent it, so a channel's origin type has no bearing on it.
enum ChatQueuedPromptMode: Sendable, Equatable {
    /// The text is a line as the operator submitted it, so it is classified
    /// again (a slash command, a plain prompt) when it leaves the queue.
    case submittedLine
    /// The text is already a prompt, for example a transcribed voice message,
    /// and runs without being classified again.
    case directPrompt
}

/// A prompt accepted while the session was already busy.
///
/// The queue carries the origin of the prompt without knowing what it is: the
/// reply, the consent request and any failure go back to whoever sent it, and
/// that is a channel concern. The Chat layer therefore takes the origin as a
/// parameter and never names a channel type; each channel supplies its own
/// (the terminal supplies its local/Telegram origin).
struct ChatQueuedPrompt<Origin: Sendable>: Sendable {
    let text: String
    let origin: Origin
    let mode: ChatQueuedPromptMode

    init(
        text: String,
        origin: Origin,
        mode: ChatQueuedPromptMode = .submittedLine
    ) {
        self.text = text
        self.origin = origin
        self.mode = mode
    }
}

extension ChatQueuedPrompt: Equatable where Origin: Equatable {}
