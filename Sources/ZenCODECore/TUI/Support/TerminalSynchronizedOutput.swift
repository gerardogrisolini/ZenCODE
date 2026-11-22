//
//  TerminalSynchronizedOutput.swift
//  ZenCODE
//

import Foundation
import ZenCODERuntime

/// Presents each physical TUI write as one atomic frame through Synchronized
/// Output (DECSET 2026): the terminal buffers everything between the begin and
/// end markers and paints it at once, so a redraw of the reserved queue or of
/// transcript text cannot tear or flicker. Terminals without the mode ignore
/// both markers.
///
/// Only the production sink is wrapped. Writes with an injected sink (tests)
/// and overlay writes keep their exact bytes, and `TerminalPrimaryScreen`
/// itself never emits the markers, which keeps its output characterization
/// byte-stable.
enum TerminalSynchronizedOutput {
    static let begin = "\u{1B}[?2026h"
    static let end = "\u{1B}[?2026l"

    /// `text` enclosed in a single begin/end pair, to be written in one call.
    static func frame(_ text: String) -> String {
        begin + text + end
    }

    /// Writes `text` through the process-wide output serialization.
    ///
    /// With an injected `sink` the text is forwarded unchanged. Otherwise the
    /// frame goes to `output` as a single write, and a terminating signal
    /// arriving meanwhile resets the mode (see `restoration`). An empty `text`
    /// writes nothing, markers included.
    static func write(
        _ text: String,
        output: FileHandle?,
        sink: (@Sendable (String) -> Void)?,
        restoration: TerminalSignalRestoration = .shared
    ) {
        guard !text.isEmpty else { return }
        guard sink == nil else {
            TerminalOutputSynchronization.write(text, output: output, sink: sink)
            return
        }
        restoration.withSynchronizedFrame {
            TerminalOutputSynchronization.write(frame(text), output: output, sink: nil)
        }
    }
}
