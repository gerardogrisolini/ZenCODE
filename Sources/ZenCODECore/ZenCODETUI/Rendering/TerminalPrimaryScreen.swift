//  Created by Gerardo Grisolini on 30/05/26.
//
// TerminalPrimaryScreen.swift
import Foundation
import Synchronization

/// Owns ONLY the reserved tail. Transcript output uses native LF/DECSTBM
/// scrolling; resize never clears or replays transcript/history. All state and
/// terminal writes are serialized by TerminalOutputSynchronization.
final class TerminalPrimaryScreen: @unchecked Sendable {
    struct Geometry: Equatable, Sendable { var rows: Int; var columns: Int }
    struct Modal: Equatable, Sendable {
        var title: String
        var help: [String]
        var lines: [TerminalCheckboxMenu.RenderedMenuLine]
        var focusedIndex: Int
        var input: String? = nil
        var inputCursor: Int? = nil
        /// Non-selectable context lines (for example a summary table) drawn
        /// inside the menu frame between the help text and the items, so they
        /// stay visible even when a standalone menu owns the alternate screen.
        var header: [String] = []
    }
    private enum Presentation: Equatable, Sendable {
        case menu(Modal)
        case dialog(TerminalDialogPresentation)
    }
    struct Anchor: Equatable, Sendable {
        var screenID: UUID
        var revision: UInt64
        var resizeGeneration: UInt64
    }
    private static let registered = Mutex<TerminalPrimaryScreen?>(nil)
    static var active: TerminalPrimaryScreen? { registered.withLock { $0 } }
    private let id = UUID()
    private let output: @Sendable (String) -> Void
    private let reports: TerminalCursorReport
    private let resizeGeneration: @Sendable () -> UInt64
    private var fileDescriptor: Int32?
    private var geometry = Geometry(rows: 24, columns: 100)
    private var footerRows = 0
    private var footer = ""
    private var reservedRows = 0
    private var modals: [(id: UUID, value: Presentation?)] = []
    private var revision: UInt64 = 0
    private var installed = false
    private var standalone = false
    private var cursorRow = 1
    private var stream = TerminalStreamingText()
    private var seenResize: UInt64
    private var queryGeneration: UInt64?
    private var queuedOutput: [String] = []
    private var disabled = false
    private var lastAppendOnlyInput: String?
    private var draft: (text: String, cursor: Int)?
    private var subscription: TerminalResizeCoordinator.Subscription?
    private var chromeTop: Int { max(2, min(geometry.rows, geometry.rows - reservedRows + 1)) }
    private var height: Int { chromeTop - 1 }
    var isAppendOnly: Bool { TerminalOutputSynchronization.withTransaction { disabled } }
    var anchor: Anchor { TerminalOutputSynchronization.withTransaction {
        Anchor(screenID: id, revision: revision, resizeGeneration: resizeGeneration())
    } }
    var validReceipt: Anchor? { usableAnchor }
    private var usableAnchor: Anchor? { TerminalOutputSynchronization.withTransaction {
        guard installed, !disabled, queryGeneration == nil, seenResize == resizeGeneration() else { return nil }
        return anchor
    } }

    convenience init(output: @escaping @Sendable (String) -> Void) {
        self.init(reports: .shared, output: output)
    }
    init(reports: TerminalCursorReport,
         resizeGeneration: @escaping @Sendable () -> UInt64 = { TerminalResizeCoordinator.shared.physicalGeneration() },
         output: @escaping @Sendable (String) -> Void) {
        self.output = output
        self.reports = reports
        self.resizeGeneration = resizeGeneration
        self.seenResize = resizeGeneration()
    }

    func prepareSession() {
        TerminalOutputSynchronization.withTransaction {
            // A restart may arrive before stop/the debounced resize callback.
            // Flush the old session before resetting any ownership state.
            if installed || queryGeneration != nil || !queuedOutput.isEmpty { stop() }
            disabled = false
            installed = false
            queryGeneration = nil
            modals.removeAll()
            stream = TerminalStreamingText()
            seenResize = resizeGeneration()
            lastAppendOnlyInput = nil
            reports.beginSession()
        }
    }
    func rememberInput(text: String, cursorIndex: Int) {
        TerminalOutputSynchronization.withTransaction {
            draft = (text, cursorIndex)
            showAppendOnlyInput(text: text, cursorIndex: cursorIndex)
        }
    }

    func handles(_ handle: FileHandle) -> Bool {
        guard let fileDescriptor else { return false }
        return handle.fileDescriptor == fileDescriptor
            || TerminalWidth.sharesTerminalCursor(first: fileDescriptor, second: handle.fileDescriptor) == true
    }
    func activate(fileDescriptor: Int32) {
        TerminalOutputSynchronization.withTransaction {
            self.fileDescriptor = fileDescriptor
            Self.registered.withLock { $0 = self }
            reports.beginSession()
            TerminalOutputSynchronization.installWriter { [weak self] text, handle in
                guard let self, self.handles(handle) else { return false }
                self.append(text)
                return true
            }
            subscription = TerminalResizeCoordinator.shared.subscribe { [weak self] in
                self?.noteResize()
            }
        }
    }
    func deactivate() {
        subscription?.cancel(); subscription = nil
        let removed = Self.registered.withLock { value -> Bool in
            guard value === self else { return false }
            value = nil
            return true
        }
        if removed { TerminalOutputSynchronization.installWriter(nil) }
    }
    private func noteResize() {
        TerminalOutputSynchronization.withTransaction {
            guard !disabled else { return }
            reports.recordDiagnostic("screen.resize seen=\(seenResize) physical=\(resizeGeneration()) query=\(queryGeneration.map(String.init) ?? "none")")
            if seenResize != resizeGeneration() { reports.suspendInput() }
            if queryGeneration != nil, queryGeneration != resizeGeneration() {
                enterAppendOnly(reason: "terminal resized during cursor report")
            }
            revision &+= 1
        }
    }

    func commitFooter(geometry: Geometry, reservedRows: Int, sequence: String, rebuild: Bool = false) {
        TerminalOutputSynchronization.withTransaction {
            guard !disabled else { return }
            if let queryGeneration, queryGeneration != resizeGeneration() {
                enterAppendOnly(reason: "terminal resized during cursor report")
                return
            }
            let oldTop = chromeTop
            let changedGeometry = self.geometry != geometry
            self.geometry = geometry
            footerRows = min(max(0, reservedRows), max(0, geometry.rows - 2))
            footer = sequence.replacingOccurrences(of: "\u{1B}7", with: "")
                .replacingOccurrences(of: "\u{1B}8", with: "")
            self.reservedRows = footerRows + modalRowCount()
            if !installed {
                installed = true
                // Allocate blank rows by native scrolling before touching them.
                // Unknown shell/setup output is never erased.
                cursorRow = height
                output("\u{1B}[?6l\u{1B}[r\u{1B}[\(geometry.rows);1H"
                    + String(repeating: "\r\n", count: self.reservedRows + 1)
                    + margins + surfaces() + park())
                return
            }
            if !standalone && (rebuild || changedGeometry || seenResize != resizeGeneration()) {
                requestAnchor()
            } else if queryGeneration == nil {
                relocateChrome(from: oldTop)
            }
        }
    }

    private func requestAnchor() {
        guard !disabled, queryGeneration == nil else { return }
        let generation = resizeGeneration()
        queryGeneration = generation
        reports.recordDiagnostic("screen.query generation=\(generation) rows=\(geometry.rows) columns=\(geometry.columns) reserved=\(reservedRows)")
        revision &+= 1
        // request only arms the demultiplexer. It never reads or acquires the
        // raw-input lock, and this transaction is NOT held while waiting.
        guard reports.request(completion: { [weak self] result in
            self?.completeAnchor(result, generation: generation)
        }) else {
            enterAppendOnly(reason: "cursor report unavailable")
            return
        }
        output("\u{1B}[6n")
        reports.recordDiagnostic("screen.query.written generation=\(generation)")
    }

    private func completeAnchor(_ result: Result<TerminalCursorReport.Position, TerminalCursorReport.Failure>, generation: UInt64) {
        reports.recordDiagnostic("screen.completion.wait generation=\(generation) result=\(result)")
        TerminalOutputSynchronization.withTransaction {
            reports.recordDiagnostic("screen.completion.locked generation=\(generation) physical=\(resizeGeneration()) query=\(queryGeneration.map(String.init) ?? "none") disabled=\(disabled) rows=\(geometry.rows) columns=\(geometry.columns) reserved=\(reservedRows)")
            guard !disabled, queryGeneration == generation else { return }
            guard generation == resizeGeneration(),
                  case let .success(position) = result,
                  position.column == 1, position.row > 1, position.row <= geometry.rows,
                  geometry.rows > reservedRows + 1, geometry.columns > 1 else {
                enterAppendOnly(reason: "cursor report failed or stale")
                return
            }
            // The old chrome start is the only erase authority after reflow.
            // The blank gap above it has no wrap metadata. The final paragraph
            // itself was reflowed by the terminal, not by an application replay.
            let gap = parkedGap
            cursorRow = max(1, position.row - gap)
            let positionInLine = stream.position(columns: geometry.columns)
            let end = stream.finalPosition(columns: geometry.columns)
            cursorRow -= max(0, end.row - positionInLine.row)
            guard cursorRow > 0 else { enterAppendOnly(reason: "cursor anchor outside viewport"); return }
            seenResize = generation
            queryGeneration = nil
            reports.resumeInput()
            relocateChrome(from: position.row, afterResize: true)
            let pending = queuedOutput
            queuedOutput.removeAll(keepingCapacity: true)
            for text in pending { append(text) }
        }
    }
    private var parkedGap = 1

    private func relocateChrome(from oldTop: Int, afterResize: Bool = false) {
        guard !disabled else { return }
        if oldTop == chromeTop, !afterResize {
            output(surfaces() + park())
            return
        }
        var sequence = cup(oldTop) + "\u{1B}[0J"
        if cursorRow >= chromeTop {
            let amount = cursorRow - height
            sequence += "\u{1B}[1;\(oldTop - 1)r" + cup(oldTop - 1)
                + String(repeating: "\r\n", count: amount)
            cursorRow = max(1, cursorRow - amount)
        }
        output(sequence + margins + surfaces() + park())
        revision &+= 1
    }

    /// The receipt is captured INSIDE the write transaction. A later diagnostic
    /// invalidates it instead of becoming part of a caller's owned tail.
    @discardableResult
    func append(_ text: String) -> Anchor? {
        TerminalOutputSynchronization.withTransaction {
            guard !text.isEmpty else { return usableAnchor }
            revision &+= 1
            if disabled { output(text); return nil }
            if queryGeneration != nil || seenResize != resizeGeneration() {
                reports.suspendInput()
                queuedOutput.append(text)
                return nil
            }
            var sequence = "\u{1B}[?25l" + insertion() + stream.rendition
            for token in stream.tokens(text) {
                switch token {
                case let .rendition(value):
                    stream.setRendition(value); sequence += value
                case .newline:
                    sequence += "\r\n"
                    cursorRow = min(height, cursorRow + 1)
                    stream.newline()
                case .carriageReturn:
                    sequence += "\r"; stream.carriageReturn(columns: geometry.columns)
                case .tab:
                    let count = 8 - (stream.position(columns: geometry.columns).column - 1) % 8
                    for _ in 0..<count { appendGlyph(" ", sequence: &sequence) }
                case let .glyph(value): appendGlyph(value, sequence: &sequence)
                }
            }
            output(sequence + TerminalStyle.reset + "\u{1B}]8;;\u{1B}\\" + surfaces() + park())
            return usableAnchor
        }
    }

    private func appendGlyph(_ text: String, sequence: inout String) {
        let before = stream.position(columns: geometry.columns)
        if let merged = stream.mergedGlyph(text) {
            let old = stream.glyphs[stream.index - 1]
            let start = stream.positions(columns: geometry.columns)[stream.index - 1]
            sequence += cup(max(1, cursorRow - (before.row - start.row)), start.column)
                + "\u{1B}[\(max(1, old.width))X" + old.style + merged
            stream.replaceLast(with: merged)
        } else {
            sequence += text
            stream.put(text)
        }
        let after = stream.position(columns: geometry.columns)
        cursorRow = min(height, cursorRow + after.row - before.row)
    }
    private func insertion() -> String {
        let p = stream.position(columns: geometry.columns)
        if p.column > geometry.columns, stream.index > 0 {
            let glyph = stream.glyphs[stream.index - 1]
            // CUP clears delayed wrap. Repaint exactly the last owned grapheme
            // to restore it; never replay a row or a transcript fragment.
            return cup(cursorRow, max(1, p.column - glyph.width)) + glyph.style + glyph.text
        }
        return cup(cursorRow, p.column)
    }

    @discardableResult
    func removeOwnedTail(rows: Int, expectedAnchor: Anchor? = nil) -> Bool {
        TerminalOutputSynchronization.withTransaction {
            guard !disabled, let expectedAnchor, expectedAnchor == usableAnchor,
                  rows > 0, rows < cursorRow, stream.glyphs.isEmpty else { return false }
            cursorRow -= rows
            revision &+= 1
            output(cup(cursorRow) + "\u{1B}[0J" + surfaces() + park())
            return true
        }
    }

    @discardableResult func beginModal() -> UUID {
        TerminalOutputSynchronization.withTransaction {
            let id = UUID(); modals.append((id, nil)); return id
        }
    }
    func updateModal(_ id: UUID, value: Modal) {
        updatePresentation(id, value: .menu(value))
    }
    func updateDialog(_ id: UUID, value: TerminalDialogPresentation) {
        updatePresentation(id, value: .dialog(value))
    }
    private func updatePresentation(_ id: UUID, value: Presentation) {
        TerminalOutputSynchronization.withTransaction {
            guard !disabled, let index = modals.firstIndex(where: { $0.id == id }), modals[index].value != value else { return }
            let oldTop = chromeTop
            modals[index].value = value
            reservedRows = footerRows + modalRowCount()
            guard queryGeneration == nil, seenResize == resizeGeneration() else { return }
            relocateChrome(from: oldTop)
        }
    }
    func endModal(_ id: UUID) {
        TerminalOutputSynchronization.withTransaction {
            guard let index = modals.firstIndex(where: { $0.id == id }) else { return }
            let oldTop = chromeTop
            modals.remove(at: index)
            reservedRows = footerRows + modalRowCount()
            guard !disabled, queryGeneration == nil, seenResize == resizeGeneration() else { return }
            relocateChrome(from: oldTop)
        }
    }
    func resizeStandalone(_ size: Geometry) {
        TerminalOutputSynchronization.withTransaction {
            standalone = true
            geometry = size
            seenResize = resizeGeneration()
            reservedRows = modalRowCount()
            installed = true
            cursorRow = 1
            output("\u{1B}[r\u{1B}[2J\u{1B}[H" + surfaces() + park())
        }
    }

    /// Fail closed for all menu/consent consumers. Leave unknown reflowed bytes
    /// intact, notify by appending, and keep this latch until stop/new session.
    func enterAppendOnly(reason: String) {
        TerminalOutputSynchronization.withTransaction {
            guard !disabled else { return }
            disabled = true
            queryGeneration = nil
            revision &+= 1
            reports.cancel()
            output(appendOnlyStart
                + "[ZenCODE] Terminal layout disabled (\(reason)); menu cancelled. Draft preserved.\r\n\u{1B}[?25h")
            drainQueuedOutput()
            if let draft { showAppendOnlyInput(text: draft.text, cursorIndex: draft.cursor) }
        }
    }

    /// Append-only editor projection: visible, usable text input without a fixed
    /// footer or cursor erasure over concurrent output. The reducer still owns
    /// the draft, history, editing and submit semantics.
    func showAppendOnlyInput(text: String, cursorIndex: Int) {
        TerminalOutputSynchronization.withTransaction {
            guard disabled else { return }
            let index = text.index(text.startIndex, offsetBy: min(max(0, cursorIndex), text.count))
            let projection = "> " + String(text[..<index]) + "▏" + String(text[index...])
            guard projection != lastAppendOnlyInput else { return }
            lastAppendOnlyInput = projection
            output("\r\n" + projection + "\r\n")
        }
    }
    // CUP clamps to the terminal's CURRENT physical bounds. Reset origin mode
    // and margins first: geometry can be stale after reflow or during debounce.
    // LF from the clamped bottom allocates a fresh line without erasing history.
    private var appendOnlyStart: String {
        "\u{1B}[?6l\u{1B}[r\u{1B}[?7h\u{1B}[0m\u{1B}[999999;1H\r\n"
    }
    private func drainQueuedOutput() {
        let pending = queuedOutput
        queuedOutput.removeAll(keepingCapacity: true)
        pending.forEach(output)
    }

    func stop() {
        TerminalOutputSynchronization.withTransaction {
            let hadQuery = queryGeneration != nil
            let stale = seenResize != resizeGeneration()
            // Disarm first so a synchronous cancel callback cannot render or
            // drain twice while shutdown owns the output transaction.
            queryGeneration = nil
            if installed, !disabled, !hadQuery, !stale, queuedOutput.isEmpty {
                output(cup(chromeTop) + "\u{1B}[0J\u{1B}[r" + cup(cursorRow) + "\u{1B}[?25h")
            } else if !disabled, hadQuery || stale || !queuedOutput.isEmpty {
                output(appendOnlyStart + "\u{1B}[?25h")
            } else { output("\u{1B}[r\u{1B}[?25h") }
            if hadQuery || stale { reports.cancel() }
            reports.resumeInput()
            drainQueuedOutput()
            installed = false
            deactivate()
        }
    }
    var outputRowForTesting: Int { TerminalOutputSynchronization.withTransaction { cursorRow } }
    func positionOutputForTesting(row: Int) {
        TerminalOutputSynchronization.withTransaction {
            cursorRow = min(height, max(1, row))
            stream = TerminalStreamingText()
            output(park())
        }
    }
    func clearOutputRowForTesting() {
        TerminalOutputSynchronization.withTransaction {
            output(cup(cursorRow) + "\u{1B}[2K")
            stream = TerminalStreamingText()
            output(park())
        }
    }

    private var margins: String { "\u{1B}[1;\(height)r" }
    private func cup(_ row: Int, _ column: Int = 1) -> String { "\u{1B}[\(row);\(column)H" }
    private func park() -> String {
        let position = stream.position(columns: geometry.columns)
        let end = stream.finalPosition(columns: geometry.columns)
        parkedGap = max(1, chromeTop - cursorRow - max(0, end.row - position.row))
        return cup(chromeTop) + "\u{1B}[?25l"
    }
    private func surfaces() -> String { "\u{1B}[?7l" + footer + modalSequence() + "\u{1B}[0m\u{1B}[?7h" }
    private func modalLines() -> [String] {
        guard let presentation = modals.last?.value, case let .menu(modal) = presentation else { return [] }
        let width = max(1, geometry.columns - 4)
        var items = modal.lines
        var focusedIndex = modal.focusedIndex
        if let input = modal.input {
            let marker = input.index(input.startIndex, offsetBy: min(max(0, modal.inputCursor ?? input.count), input.count))
            let prefix = (items.first?.text ?? "") + String(input[..<marker])
            let wrapped = TerminalANSIText.wrapPreservingWhitespace(prefix + "▏" + String(input[marker...]), width: width)
            focusedIndex = max(0, TerminalANSIText.wrapPreservingWhitespace(prefix + "▏", width: width).count - 1)
            items = wrapped.enumerated().map { .init(text: $0.element, itemIndex: $0.offset) }
        }
        let capacity = max(1, geometry.rows - footerRows - 4)
        let fixed = [modal.title] + modal.help + [""]
        let itemCapacity = max(1, capacity - fixed.count)
        // Items keep priority; the header only uses rows they leave free.
        let header = TerminalCheckboxMenu.visibleHeaderLines(
            modal.header,
            capacity: itemCapacity - min(items.count, itemCapacity)
        )
        let selected = TerminalCheckboxMenu.visibleItemLines(items, focusedIndex: focusedIndex, capacity: max(1, itemCapacity - header.count))
        return Array(fixed.prefix(max(0, capacity - selected.count - header.count))) + header + selected
    }
    private func dialogLines(_ dialog: TerminalDialogPresentation) -> [String] {
        dialog.visibleLines(columns: geometry.columns, capacity: max(0, geometry.rows - footerRows - 2))
    }
    private func modalRowCount() -> Int {
        guard let presentation = modals.last?.value else { return 0 }
        switch presentation {
        case .menu:
            return min(max(0, geometry.rows - footerRows - 2), modalLines().count + 2)
        case let .dialog(dialog):
            return dialogLines(dialog).count
        }
    }
    private func modalSequence() -> String {
        guard let presentation = modals.last?.value else { return "" }
        switch presentation {
        case .menu:
            return menuSequence()
        case let .dialog(dialog):
            return dialogLines(dialog).enumerated().map {
                cup(chromeTop + $0.offset) + "\u{1B}[2K" + $0.element
            }.joined()
        }
    }
    private func menuSequence() -> String {
        let width = max(1, geometry.columns - 4)
        let border = TerminalStyle.Chrome.border, reset = TerminalStyle.reset
        let rule = String(repeating: "─", count: max(0, geometry.columns - 2))
        let box = [border + "╭" + rule + "╮" + reset]
            + modalLines().map { border + "│" + reset + " " + TerminalCheckboxMenu.padded(TerminalCheckboxMenu.fitLine($0, width: width), width: width) + " " + border + "│" + reset }
            + [border + "╰" + rule + "╯" + reset]
        return Array(box.suffix(modalRowCount())).enumerated().map { cup(chromeTop + $0.offset) + "\u{1B}[2K" + $0.element }.joined()
    }
}
