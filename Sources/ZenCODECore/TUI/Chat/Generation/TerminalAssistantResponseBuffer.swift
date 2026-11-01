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
