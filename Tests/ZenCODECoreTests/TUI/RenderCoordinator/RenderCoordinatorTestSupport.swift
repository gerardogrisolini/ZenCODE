import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

// Both suites use the same capture-only renderer. Each test still owns its
// renderer and controllable clock; no shared mutable fixture is introduced.
protocol RenderCoordinatorTestSupport {}

extension RenderCoordinatorTestSupport {
    func makeRenderer(
        stdinIsTerminal: Bool = false,
        standardErrorIsTerminal: Bool,
        standardOutputIsTerminal: Bool = false,
        streamingFlushDelay: Duration? = nil,
        streamingNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        toolNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        columnWidthProvider: (@Sendable () -> Int)? = nil,
        freshColumnWidthProvider: (@Sendable () -> Int)? = nil,
        cursorTopology: TerminalChatRenderCoordinator.CursorTopology? = nil
    ) -> TerminalChatRenderCoordinator {
        let resolvedTopology: TerminalChatRenderCoordinator.CursorTopology?
        if let cursorTopology {
            resolvedTopology = cursorTopology
        } else if standardOutputIsTerminal && standardErrorIsTerminal {
            // Existing tests with two captured TTY channels model the legacy
            // one-terminal transcript explicitly.
            resolvedTopology = .shared
        } else {
            resolvedTopology = nil
        }
        return TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal,
            cursorTopology: resolvedTopology,
            capturesWrites: true,
            streamingFlushDelay: streamingFlushDelay,
            streamingNow: streamingNow,
            toolNow: toolNow,
            columnWidthProvider: columnWidthProvider,
            freshColumnWidthProvider: freshColumnWidthProvider
        )
    }

    func makeResizableRenderer(width: Int) -> (ColumnWidthBox, TerminalChatRenderCoordinator) {
        let widthBox = ColumnWidthBox(width)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        return (widthBox, renderer)
    }

    func exampleReadFileCall(id: String) -> DirectAgentToolCall {
        presentedToolCall(
            id: id,
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/Example.swift"],
            argumentsJSON: #"{"path":"/tmp/Example.swift"}"#
        )
    }

    func exampleEditFileCall(id: String) -> DirectAgentToolCall {
        presentedToolCall(
            id: id,
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "let oldValue = 1",
                "new": "let newValue = 2"
            ],
            argumentsJSON: "{}"
        )
    }

    func compactCompletionText(for toolCall: DirectAgentToolCall, newline: Bool) -> String {
        TerminalChat.compactToolTerminalText(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "✅",
                statusDetail: "0ms"
            ),
            lineInset: "",
            newline: newline
        )
    }

    func makeChatStatusBar(row: Int) async -> TerminalStatusBar {
        let statusBar = TerminalStatusBar(isEnabled: true) { _ in }
        await statusBar.configureForTesting(row: row, columns: 80)
        await statusBar.updateInputPanel(
            text: "draft",
            cursorIndex: 5,
            modeText: "Chat",
            helpText: "Enter"
        )
        return statusBar
    }
}

// Raw and ANSI-stripped projections are separate so cursor/control assertions
// cannot accidentally inspect normalized text. Slices preserve event order.
extension Collection where Element == TerminalChatRenderCoordinator.WriteEvent {
    func renderedText(on channel: TerminalChatRenderCoordinator.OutputChannel? = nil) -> String {
        if let channel {
            return filter { $0.channel == channel }.map(\.text).joined()
        }
        return map(\.text).joined()
    }

    func plainText(on channel: TerminalChatRenderCoordinator.OutputChannel? = nil) -> String {
        TerminalANSIText.stripANSI(renderedText(on: channel))
    }
}

extension TerminalChatRenderCoordinator {
    // The common live-overview fixture remembers the signature without forcing
    // a refresh. Tests of other policies keep calling renderSubAgentOverview.
    @discardableResult
    func renderRememberedSubAgentOverview(
        signature: String,
        text: String,
        partialResponses: [SubAgentPartialResponse] = [],
        responses: [SubAgentMarkdownResponse] = [],
        revision: Int? = nil,
        origin: OverviewPublicationOrigin = .automatic,
        overviewBatchID: String? = nil,
        maximumInPlaceRows: Int? = nil
    ) -> OverviewRenderResult {
        renderSubAgentOverview(
            signature: signature,
            text: text,
            partialResponses: partialResponses,
            responses: responses,
            revision: revision,
            force: false,
            rememberSignature: true,
            origin: origin,
            overviewBatchID: overviewBatchID,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func capturedText(on channel: OutputChannel? = nil, droppingFirst count: Int = 0) -> String {
        capturedWriteEvents().dropFirst(count).renderedText(on: channel)
    }

    func capturedPlainText(on channel: OutputChannel? = nil, droppingFirst count: Int = 0) -> String {
        TerminalANSIText.stripANSI(capturedText(on: channel, droppingFirst: count))
    }
}

/// Mutable, thread-safe-ish box for simulating terminal resize in tests.
/// Tests are single-threaded (async on one task), so plain `var` is safe;
/// `@unchecked Sendable` satisfies the `@Sendable` closure requirement.
final class ColumnWidthBox: @unchecked Sendable {
    var width: Int
    var readCount = 0
    init(_ width: Int) { self.width = width }
}

/// Controllable clock for deterministic leading-edge flush tests.  Because
/// the render coordinator is an actor and tests are single-tasked, the plain
/// `var` is safe to mutate between `await` points; `@unchecked Sendable`
/// satisfies the `@Sendable` closure requirement.
final class StreamingClock: @unchecked Sendable {
    private(set) var now = ContinuousClock().now
    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }
}

/// Detects a CSI cursor-up sequence (`ESC [ <digits> A`), the destructive
/// move emitted only by ``TerminalChatRenderCoordinator``'s
/// ``clearOwnedToolRows``. Color/reset codes end in `m`, erase-line ends in
/// `K`, and cursor-down ends in `B`, so none of them ever produce a false
/// positive here.
func containsCursorUpSequence(_ text: String) -> Bool {
    var pos = text.startIndex
    while let r = text.range(of: "\u{1B}[", range: pos..<text.endIndex) {
        var i = r.upperBound
        var sawDigit = false
        while i < text.endIndex, text[i].isNumber {
            sawDigit = true
            i = text.index(after: i)
        }
        if sawDigit, i < text.endIndex, text[i] == "A" {
            return true
        }
        pos = r.upperBound
    }
    return false
}
