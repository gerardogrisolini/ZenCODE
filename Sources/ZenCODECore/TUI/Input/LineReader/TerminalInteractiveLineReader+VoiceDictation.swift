//
//  TerminalInteractiveLineReader+VoiceDictation.swift
//  ZenCODE
//
//  Voice mode previews the speech recognized so far at the end of the panel
//  draft and sends the whole visible draft. The voice controllers call in
//  from their own actors, so these entry points never wait on terminal
//  output: they mutate under the panel lock and only enqueue a redraw.
//

import Foundation

extension TerminalInteractiveLineReader {
    /// Installs (or removes, with nil) what is told when an edit ends the
    /// dictation shown in the draft. Each voice controller numbers its
    /// dictations from 1, so installing a handler starts a new session: a
    /// preview left by the previous controller becomes ordinary text.
    func setVoiceDictationEndedHandler(_ handler: (@Sendable (UInt64) -> Void)?) {
        withPanelLock { state in
            if handler != nil {
                state.voiceDictation = TerminalPromptDictation()
            }
            state.voiceDictationEndedHandler = handler
        }
    }

    /// Shows `text` as the preview of dictation `id` at the end of the
    /// draft; empty text removes it. Ignored once an edit ended `id`.
    func setVoiceDictation(id: UInt64, text: String) {
        let changed = withPanelLock { state -> Bool in
            state.voiceDictation.show(id: id, text: text, in: &state.editor)
        }
        if changed {
            requestPanelRender()
        }
    }

    /// Voice sends dictation `id` with its final `text`: returns the whole
    /// draft to send (typed text, then `text`) and clears it without
    /// recording history. Nil when an edit already ended the dictation.
    func takeVoiceDictation(id: UInt64, text: String) -> String? {
        let taken = withPanelLock { state -> (text: String?, changed: Bool) in
            let before = state.editor
            let text = state.voiceDictation.take(id: id, text: text, from: &state.editor)
            return (text, state.editor != before)
        }
        if taken.changed {
            requestPanelRender()
        }
        return taken.text
    }

    /// Ends the dictation shown in the draft, if any. Returns the call that
    /// tells voice, to be made once the panel lock is released.
    func endVoiceDictationLocked(state: inout State) -> (@Sendable () -> Void)? {
        guard let id = state.voiceDictation.end(),
              let handler = state.voiceDictationEndedHandler else {
            return nil
        }
        return { handler(id) }
    }
}
