public nonisolated struct ToolExecutionOutput: Sendable {
    public let text: String
    public let rawResult: JSONValue?

    public init(text: String, rawResult: JSONValue?) {
        self.text = text
        self.rawResult = rawResult
    }
}
