/// Runtime content events do not identify final answers. Hold a single assistant
/// block until a tool boundary proves it is commentary, or turn completion proves
/// it is the answer. This state is presentation-only, never persisted.
actor TerminalAssistantResponseBuffer {
    private var pending = ""
    private var receivedContent = false

    func append(_ delta: String) {
        guard !delta.isEmpty else { return }
        receivedContent = true
        pending += delta
    }

    func takePending() -> String {
        defer { pending = "" }
        return pending
    }

    /// The turn moved onto the terminal after running on another channel,
    /// and the catch-up rendered what it streamed there, the block held
    /// here included: that block is dropped, and the turn counts as one that
    /// streamed content, so its end shows only what streams from now on
    /// (`Done.` when nothing does) instead of the whole response again.
    func discardPresentedContent() {
        pending = ""
        receivedContent = true
    }

    /// Whether a block is waiting for its tool boundary or the turn end,
    /// without taking it: the Telegram overview barrier reads it to tell that
    /// the tool boundary in progress will write a comment.
    var hasPendingContent: Bool {
        !pending.isEmpty
    }

    func finalContent(fallback: String) -> String {
        receivedContent ? takePending() : fallback
    }
}
