//
//  TerminalToolCallPreviewFormatter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/11/26.
//

import Foundation
import ZenCODERuntime

/// Draws a file write or edit while the model is still writing its tool call,
/// as ds4-agent does: a header row naming the canonical tool, then the source
/// text printed as it arrives and repainted in color one row at a time. The
/// header never carries the target path, whichever order the model writes its
/// arguments in: the path is only read, to choose the language and to identify
/// the call (``DrawnCall``), and the compact tool block that follows the
/// preview shows it on its status row. The old and new text of every edit of a
/// `local.multiEdit` call arrive inside the JSON of its `edits` argument: they
/// are decoded as they stream (see ``EditListDecoder``) and drawn one after the
/// other, as the separate arguments of `local.editFile` are, without the JSON
/// around them.
///
/// A pure state machine: it takes the ``DirectAgentToolCallPreview`` fragments
/// in stream order and returns the exact text to write, without any I/O.
/// ``TerminalChatRenderCoordinator`` owns the value and performs the writes.
///
/// Every scalar of source text is written as soon as it arrives, without
/// color, and kept in the buffer of the current row. At the end of a row the
/// row is repainted with the syntax colors only when the repaint covers exactly
/// the cells already written: a carriage return, the same inset and diff
/// marker, and the same printable-ASCII text, on a row narrower than the
/// terminal. Nothing is erased, so the repaint needs no erase sequence and no
/// vertical cursor movement. There is no row limit, no elision, no background,
/// and no line number.
///
/// Other output interrupts a call without ending it (``interrupt(columns:)``):
/// its rows are closed, but the call is remembered, and its next drawn source
/// text reopens the header with the tool name alone and goes on from a new
/// row, as a streamed thought reopens its title. A path that streams while the
/// call is suspended writes nothing, so it reopens nothing.
struct TerminalToolCallPreviewFormatter: Sendable {
    /// What one argument of a drawn tool shows.
    enum ParameterRole: Sendable, Equatable {
        /// The target path: it selects the language of the source text and
        /// identifies the call, but it is never drawn.
        case path
        /// Source text; each of its rows starts with `marker` when there is one.
        case code(marker: CodeMarker?)
        /// A JSON array of edits: the `old` and `new` strings of its objects are
        /// source text with the markers of an edit, in order and without a
        /// separator; the rest of the JSON is not drawn.
        case editList
    }

    /// The diff marker that starts every row of an edit's old or new text. It
    /// is terminal presentation, not source: it is never highlighted.
    enum CodeMarker: Sendable, Equatable {
        case removal
        case addition

        var text: String {
            switch self {
            case .removal: "- "
            case .addition: "+ "
            }
        }
    }

    /// A tool whose calls are drawn, with the role of each argument it shows.
    /// Every other argument is not drawn.
    struct DrawnTool: Sendable, Equatable {
        /// The canonical tool name the header shows, so the header of a drawn
        /// call is the header of the tool block that follows it.
        let name: String
        let parameters: [String: ParameterRole]
    }

    /// What a drawn call showed when it ended: the canonical tool name, the
    /// path it received, and whether its rows were still open on screen (no
    /// other output followed its header). The tool block that follows the
    /// call uses it to avoid repeating the header.
    struct DrawnCall: Sendable, Equatable {
        let toolName: String
        let path: String
        let endedOnScreen: Bool
    }

    private static let tabWidth = 4

    private static let contentParameters: [String: ParameterRole] = [
        "path": .path,
        "file_path": .path,
        "content": .code(marker: nil)
    ]

    private static let editParameters: [String: ParameterRole] = [
        "path": .path,
        "file_path": .path,
        "old": .code(marker: .removal),
        "new": .code(marker: .addition)
    ]

    private static let multiEditParameters: [String: ParameterRole] = [
        "path": .path,
        "file_path": .path,
        "edits": .editList
    ]

    /// The drawn tool named `name`, compared on letters and digits only and
    /// without case, so `local_write` is `local.write`; `nil` for any
    /// tool that is not drawn (`local.applyPatch` included).
    static func drawnTool(named name: String) -> DrawnTool? {
        switch normalizedToolName(name) {
        case "localwrite":
            DrawnTool(name: "local.write", parameters: contentParameters)
        case "localappend":
            DrawnTool(name: "local.append", parameters: contentParameters)
        case "localeditfile":
            DrawnTool(name: "local.editFile", parameters: editParameters)
        case "localreplace":
            DrawnTool(name: "local.replace", parameters: editParameters)
        case "localmultiedit":
            DrawnTool(name: "local.multiEdit", parameters: multiEditParameters)
        default:
            nil
        }
    }

    static func drawsTool(named name: String) -> Bool {
        drawnTool(named: name) != nil
    }

    static func normalizedToolName(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Colors and repaints are written only to an interactive terminal; any
    /// other channel receives plain text without carriage returns.
    private let isInteractive: Bool
    /// The chat margin that the writer places before the first visible cell of
    /// a row; a repaint rewrites it after its carriage return.
    private let lineInset: String
    private let palette: TerminalMarkdownPalette

    private var tool: DrawnTool?
    private var headerIsOpen = false
    /// The open argument when it is drawn; `nil` between arguments and inside
    /// an argument that is not drawn.
    private var parameter: ParameterRole?
    /// The reading of the open argument when it is an edit list: it keeps its
    /// place in the JSON across fragments, and across an interruption.
    private var editList = EditListDecoder()
    private var path = ""
    private var language: String?
    /// The terminal-safe text written on the current source row, without the
    /// inset and the marker.
    private var row = ""
    private var rowWidth = 0
    private var rowIsPrintableASCII = true
    /// A carriage return ended the row: a line feed right after it completes
    /// the same CRLF break instead of starting another row.
    private var swallowsLineFeed = false
    /// An interruption ended a non-empty source row on screen: a line break
    /// right after the call reopens completes that row instead of drawing an
    /// empty one that is not in the source.
    private var rowWasEndedByInterruption = false

    init(
        isInteractive: Bool,
        lineInset: String,
        palette: TerminalMarkdownPalette = .detected
    ) {
        self.isInteractive = isInteractive
        self.lineInset = lineInset
        self.palette = palette
    }

    /// A drawn call is open: its rows are on screen and its end is pending.
    var isOpen: Bool {
        tool != nil && !isSuspended
    }

    /// A drawn call was interrupted by other output and is remembered: none of
    /// its rows is open on screen until its next drawn text
    /// (``resumes(with:)``), and its end or a new call forgets it.
    private(set) var isSuspended = false

    /// Whether `preview` reopens the suspended call: text of an argument it
    /// draws that writes something. The caller prepares the transcript
    /// first, as for a start.
    func resumes(with preview: DirectAgentToolCallPreview) -> Bool {
        guard isSuspended, parameter != nil, case let .parameterText(text) = preview else {
            return false
        }
        return draws(text)
    }

    /// Consumes one fragment and returns the text to write. Fragments that
    /// arrive without the start of a drawn tool return nothing; while the call
    /// is suspended only its drawn text returns something, the reopened header
    /// first. `columns` is read only when a row may be repainted, so the
    /// caller can supply the width measured at that moment.
    mutating func consume(
        _ preview: DirectAgentToolCallPreview,
        columns: () -> Int
    ) -> String {
        switch preview {
        case let .toolStarted(name):
            let ended = finish(columns: columns)
            return ended.text + (begin(toolNamed: name) ?? "")
        case let .parameterStarted(name):
            return beginParameter(named: name, columns: columns)
        case let .parameterText(text):
            return appendParameterText(text, columns: columns)
        case .parameterEnded:
            return endParameter(columns: columns)
        case .ended:
            return finish(columns: columns).text
        }
    }

    /// Opens the header row of a call to `name` and returns it, or returns
    /// `nil` and draws nothing when `name` is not a drawn tool. The caller
    /// finishes an open call first (see ``finish(columns:)``), so it can
    /// prepare the transcript between the two.
    mutating func begin(toolNamed name: String) -> String? {
        resetCall()
        guard let drawnTool = Self.drawnTool(named: name) else {
            return nil
        }
        tool = drawnTool
        headerIsOpen = true
        return headerTitle()
    }

    /// Ends the call, whatever its state. An open call's current source row
    /// is repainted when it can be and closed, the header row (the tool name
    /// alone) is closed, and the cursor is left at the start of a row; a
    /// suspended call has nothing open and is forgotten without output.
    /// Returns the text to write and what the call drew (its path included,
    /// which the preview itself never draws), or `nil` when no drawn call was
    /// open or suspended; other output followed the header of a suspended
    /// call, so that header is not recorded as on screen.
    mutating func finish(columns: () -> Int) -> (text: String, drawn: DrawnCall?) {
        guard let tool else {
            return ("", nil)
        }
        let output = isSuspended ? "" : endParameter(columns: columns) + closeHeader()
        let drawn = DrawnCall(
            toolName: tool.name,
            path: path,
            endedOnScreen: !isSuspended
        )
        resetCall()
        return (output, drawn)
    }

    /// Closes the open call's rows before other output, with the same text as
    /// ``finish(columns:)``, but suspends the call instead of ending it: its
    /// tool, the path received so far (which still selects the language and
    /// identifies the call), and the open argument with its role are kept for
    /// its next drawn text.
    mutating func interrupt(columns: () -> Int) -> String {
        guard isOpen else {
            return ""
        }
        // A carriage return that ended the last row still pairs with the
        // line feed that may follow it.
        let pairsLineFeed = swallowsLineFeed
        let endsSourceRow = !row.isEmpty
        let output = closeRow(columns: columns) + closeHeader()
        swallowsLineFeed = pairsLineFeed
        rowWasEndedByInterruption = endsSourceRow
        isSuspended = true
        return output
    }

    // MARK: - Arguments

    private mutating func beginParameter(
        named name: String,
        columns: () -> Int
    ) -> String {
        guard let tool else {
            return ""
        }
        // An argument left open ends where the next one starts.
        var output = endParameter(columns: columns)
        parameter = tool.parameters[name]
        switch parameter {
        case .path:
            path = ""
        case .code, .editList:
            output += closeHeader()
            // Content that arrives before any path is highlighted with the
            // generic profile, like an unknown extension.
            language = path.isEmpty ? nil : ToolLanguageHint.hint(forPath: path)
            resetRow()
            // An edit list is read from the first scalar of its JSON.
            editList = EditListDecoder()
        case nil:
            break
        }
        return output
    }

    private mutating func appendParameterText(
        _ text: String,
        columns: () -> Int
    ) -> String {
        guard tool != nil, let parameter, !text.isEmpty else {
            return ""
        }
        var output = isSuspended && draws(text) ? reopen() : ""
        switch parameter {
        case .path:
            output += appendPath(text)
        case let .code(marker):
            for scalar in text.unicodeScalars {
                output += appendCode(scalar, marker: marker, columns: columns)
            }
        case .editList:
            for scalar in text.unicodeScalars {
                output += appendEdit(scalar, columns: columns)
            }
        }
        // A call that stays suspended took only line breaks that complete
        // the row its interruption ended: they write nothing.
        return isSuspended ? "" : output
    }

    /// Whether `text` of the open argument writes anything. A path is never
    /// drawn, so its text writes nothing; in source text only the line breaks
    /// that complete a row already ended on screen write nothing. The text of
    /// an edit list is decoded first, on a copy of the reading, and only the
    /// source text it decodes to counts: the JSON around it, and the end of a
    /// string, write nothing.
    private func draws(_ text: String) -> Bool {
        switch parameter {
        case .code:
            break
        case .editList:
            return drawsEdit(text)
        case .path, nil:
            return false
        }
        var scalars = text.unicodeScalars[...]
        if rowWasEndedByInterruption, let first = scalars.first, first == "\n" || first == "\r" {
            scalars = scalars.dropFirst()
            if first == "\r", scalars.first == "\n" {
                scalars = scalars.dropFirst()
            }
        } else if swallowsLineFeed, scalars.first == "\n" {
            scalars = scalars.dropFirst()
        }
        return !scalars.isEmpty
    }

    /// ``draws(_:)`` for an edit list: the decoded scalars go through the
    /// same line-break rules as ``appendEdit(_:columns:)``, on copies of the
    /// state they change.
    private func drawsEdit(_ text: String) -> Bool {
        var decoder = editList
        var rowWasEnded = rowWasEndedByInterruption
        var pairsLineFeed = swallowsLineFeed
        for scalar in text.unicodeScalars {
            for event in decoder.consume(scalar) {
                switch event {
                case let .scalar(decoded, _):
                    if !Self.absorbsLineBreak(
                        decoded,
                        rowWasEnded: &rowWasEnded,
                        pairsLineFeed: &pairsLineFeed
                    ) {
                        return true
                    }
                case .stringEnded:
                    // The end of a string closes its row and its line-break state.
                    rowWasEnded = false
                    pairsLineFeed = false
                }
            }
        }
        return false
    }

    private mutating func endParameter(columns: () -> Int) -> String {
        let output = closeRow(columns: columns)
        parameter = nil
        swallowsLineFeed = false
        return output
    }

    /// Repaints and ends the current source row, if there is one, with the
    /// marker of the argument open now: the one of its text, or the one of the
    /// string of an edit list that is open.
    private mutating func closeRow(columns: () -> Int) -> String {
        switch parameter {
        case let .code(marker):
            return closeRow(marker: marker, columns: columns)
        case .editList:
            return closeRow(marker: editList.openMarker, columns: columns)
        case .path, nil:
            resetRow()
            return ""
        }
    }

    private mutating func closeRow(marker: CodeMarker?, columns: () -> Int) -> String {
        guard !row.isEmpty else {
            resetRow()
            return ""
        }
        let output = repaint(marker: marker, columns: columns) + "\n"
        resetRow()
        return output
    }

    // MARK: - Header

    /// The path is only accumulated: it selects the language of the source
    /// text and identifies the call, but the header stays the tool name alone,
    /// so it is the same whether the path arrives before or after the source
    /// text, and nothing is written. The compact tool block shows the path on
    /// its status row.
    private mutating func appendPath(_ text: String) -> String {
        path += text
        return ""
    }

    private func headerTitle() -> String {
        guard let tool else {
            return ""
        }
        let title = "\(ToolCallPresentation.toolIcon(for: tool.name))  \(tool.name)"
        return styled(title, TerminalStyle.Tool.title)
    }

    /// Reopens the header of the suspended call with the tool name alone and
    /// closes it at once: only source text reopens a call, and it goes on from
    /// the row after the header.
    private mutating func reopen() -> String {
        isSuspended = false
        headerIsOpen = true
        return headerTitle() + closeHeader()
    }

    private mutating func closeHeader() -> String {
        guard headerIsOpen else {
            return ""
        }
        headerIsOpen = false
        return "\n"
    }

    // MARK: - Source rows

    /// One scalar of an edit list: the source text it decodes to is drawn row
    /// by row with the marker of its string, and the end of a string closes
    /// its row, as the end of the `old` or `new` argument of `local.editFile`
    /// does. Edits follow one another without a separator.
    private mutating func appendEdit(
        _ scalar: Unicode.Scalar,
        columns: () -> Int
    ) -> String {
        var output = ""
        for event in editList.consume(scalar) {
            switch event {
            case let .scalar(decoded, marker):
                output += appendCode(decoded, marker: marker, columns: columns)
            case let .stringEnded(marker):
                output += closeRow(marker: marker, columns: columns)
            }
        }
        return output
    }

    /// Whether `scalar` is a line break that completes a row already ended on
    /// screen, and so writes nothing: the line break right after an
    /// interruption that ended a row, or the line feed of a CRLF whose carriage
    /// return ended the row. `rowWasEnded` and `pairsLineFeed` are the state of
    /// ``rowWasEndedByInterruption`` and ``swallowsLineFeed``, updated as the
    /// scalar changes them.
    private static func absorbsLineBreak(
        _ scalar: Unicode.Scalar,
        rowWasEnded: inout Bool,
        pairsLineFeed: inout Bool
    ) -> Bool {
        if rowWasEnded {
            rowWasEnded = false
            if scalar == "\n" || scalar == "\r" {
                // The interruption already broke this row on screen.
                pairsLineFeed = scalar == "\r"
                return true
            }
        }
        if pairsLineFeed {
            pairsLineFeed = false
            if scalar == "\n" {
                return true
            }
        }
        return false
    }

    private mutating func appendCode(
        _ scalar: Unicode.Scalar,
        marker: CodeMarker?,
        columns: () -> Int
    ) -> String {
        if Self.absorbsLineBreak(
            scalar,
            rowWasEnded: &rowWasEndedByInterruption,
            pairsLineFeed: &swallowsLineFeed
        ) {
            return ""
        }
        switch scalar {
        case "\n", "\r":
            // CRLF and a lone CR break the row like LF, as the tool blocks
            // normalize them; neither reaches the terminal as a cursor move.
            let output = (row.isEmpty ? markerText(marker) : repaint(marker: marker, columns: columns))
                + "\n"
            resetRow()
            swallowsLineFeed = scalar == "\r"
            return output
        case "\t":
            // Tabs are expanded from the source column zero, not from the
            // marker, as the diff renderer does.
            let spaces = Self.tabWidth - rowWidth % Self.tabWidth
            return appendRowText(String(repeating: " ", count: spaces), marker: marker)
        default:
            // A control scalar becomes its visible picture, a bidi or join
            // control the replacement glyph: the text written and the text
            // highlighted are the same terminal-safe text.
            return appendRowText(
                TerminalCodeBlockRenderer.terminalSafeSourceLine(String(scalar)),
                marker: marker
            )
        }
    }

    private mutating func appendRowText(_ text: String, marker: CodeMarker?) -> String {
        guard !text.isEmpty else {
            return ""
        }
        let output = (row.isEmpty ? markerText(marker) : "") + text
        row += text
        rowWidth += TerminalANSIText.visibleWidth(text)
        if rowIsPrintableASCII {
            rowIsPrintableASCII = text.unicodeScalars.allSatisfy {
                (0x20...0x7E).contains($0.value)
            }
        }
        return output
    }

    /// The colored copy of the current row, written over the plain one from
    /// its first cell, or nothing when that copy could cover different cells
    /// or would look the same. The width is read last, only for a row that
    /// would otherwise be repainted.
    private func repaint(marker: CodeMarker?, columns: () -> Int) -> String {
        guard isInteractive, !row.isEmpty, rowIsPrintableASCII else {
            return ""
        }
        let highlighted = TerminalCodeBlockRenderer.renderLine(
            row,
            language: language,
            palette: palette
        )
        guard highlighted != row,
              TerminalANSIText.stripANSI(highlighted) == row else {
            return ""
        }
        let markerWidth = marker.map { $0.text.utf8.count } ?? 0
        let rowCells = TerminalTextMetrics.displayWidth(lineInset) + markerWidth + row.utf8.count
        guard rowCells < columns() else {
            return ""
        }
        return "\r\(lineInset)\(markerText(marker))\(highlighted)\(TerminalStyle.reset)"
    }

    private func markerText(_ marker: CodeMarker?) -> String {
        guard let marker else {
            return ""
        }
        let color = marker == .removal ? palette.diffRemoval : palette.diffAddition
        return styled(marker.text, color)
    }

    private func styled(_ text: String, _ style: String) -> String {
        isInteractive ? "\(style)\(text)\(TerminalStyle.reset)" : text
    }

    private mutating func resetRow() {
        row = ""
        rowWidth = 0
        rowIsPrintableASCII = true
        swallowsLineFeed = false
        rowWasEndedByInterruption = false
    }

    private mutating func resetCall() {
        tool = nil
        isSuspended = false
        headerIsOpen = false
        parameter = nil
        editList = EditListDecoder()
        path = ""
        language = nil
        resetRow()
    }
}
