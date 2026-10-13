//
//  TerminalInteractiveLineReader+Modal.swift
//  ZenCODE
//

import Foundation

extension TerminalInteractiveLineReader {
    /// Direct prompts share the same reducer as the fallback reader but publish
    /// a bounded surface instead of echoing bytes into the transcript/footer.
    func readCompositedLine(prompt: String, shouldCancel: (@Sendable () -> Bool)?) -> String? {
        let modal = TerminalModalSession()
        defer { modal.close() }
        var editor = TerminalPromptEditor()
        return rawInput.withRawTerminal {
            while true {
                modal.update(.init(title: "", help: [],
                    lines: [.init(text: prompt, itemIndex: 0)], focusedIndex: 0,
                    input: String(editor.buffer), inputCursor: editor.cursorIndex))
                if modal.isCancelled || shouldCancel?() == true { return nil }
                let key: Key
                switch readKeyResult(pollTimeoutMilliseconds: Self.cancellationPollTimeout) {
                case let .key(value): key = value
                case .pickerEscape: key = .cancel
                case .timedOut: continue
                case .endOfInput: return nil
                }
                guard !modal.isCancelled else { return nil }
                let context = TerminalPromptEditorContext(
                    history: withPanelLock { $0.history },
                    supportsCompletions: false,
                    clearsDraftOnCancel: false
                )
                switch editor.apply(key, context: context) {
                case let .submitted(line):
                    recordHistory(line)
                    return modal.accepted(line)
                case .endOfInput: return nil
                default: continue
                }
            }
        }
    }
}
