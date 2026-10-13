// TerminalDialogPresentation.swift

/// An already-rendered single-key dialog, not a list of selectable menu items.
/// The caller owns its card/chrome; the primary screen only places these rows
/// in the shared modal area. In particular, it must not add another border.
struct TerminalDialogPresentation: Equatable, Sendable {
    let lines: [String]

    init(prompt: String) {
        var lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The surrounding newlines belong to the non-composited echo path, not
        // to the card. Do not spend scarce modal rows on that outer spacing.
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        self.lines = lines
    }

    func visibleLines(columns: Int, capacity: Int) -> [String] {
        guard columns > 0, capacity > 0 else { return [] }
        let fitted = lines.map { line in
            TerminalANSIText.visibleWidth(line) <= columns
                ? line : TerminalANSIText.truncate(line, to: columns)
        }
        guard fitted.count > capacity else { return fitted }
        // Consent actions live at the end of the rendered card. Preserve that
        // tail on short terminals, without item focus or menu scroll markers.
        // Keep the original heading and an explicit omission when space allows.
        guard capacity >= 4 else { return Array(fitted.suffix(capacity)) }
        return [fitted[0], "…"] + Array(fitted.suffix(capacity - 2))
    }
}
