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

    func finalContent(fallback: String) -> String {
        receivedContent ? takePending() : fallback
    }
}
