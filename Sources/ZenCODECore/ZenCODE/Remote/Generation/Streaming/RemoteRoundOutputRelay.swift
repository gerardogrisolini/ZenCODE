// Live output is append-only. A failed round stays visible, but its matching
// prefix must not be emitted twice when that round is regenerated.
actor RemoteRoundOutputRelay {
    private var content = Prefix()
    private var thought = Prefix()

    func beginRetry() {
        content.beginRetry()
        thought.beginRetry()
    }

    func forward(
        _ event: DirectAgentEvent,
        to onEvent: @Sendable (DirectAgentEvent) async -> Void
    ) async {
        switch event {
        case let .content(delta):
            let suffix = content.consume(delta)
            if !suffix.isEmpty { await onEvent(.content(suffix)) }
        case let .thought(delta):
            let suffix = thought.consume(delta)
            if !suffix.isEmpty { await onEvent(.thought(suffix)) }
        default:
            await onEvent(event)
        }
    }

    private struct Prefix {
        var visible: [Unicode.Scalar] = []
        var replayOffset: Int?

        mutating func beginRetry() { replayOffset = 0 }

        mutating func consume(_ delta: String) -> String {
            let scalars = Array(delta.unicodeScalars)
            var start = 0
            if var offset = replayOffset {
                while start < scalars.count, offset < visible.count,
                      scalars[start] == visible[offset] {
                    start += 1
                    offset += 1
                }
                // On divergence the old suffix remains visible. Never search
                // for later matches: only the common leading prefix is replay.
                replayOffset = start == scalars.count && offset < visible.count ? offset : nil
            }
            let suffix = scalars.dropFirst(start)
            visible.append(contentsOf: suffix)
            return String(String.UnicodeScalarView(suffix))
        }
    }
}
