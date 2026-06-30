//
//  TerminalInteractiveLineReader.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

public final class TerminalInteractiveLineReader: @unchecked Sendable {
    enum Key {
        case character(String)
        case paste(String)
        case enter
        case newline
        case tab
        case backspace
        case delete
        case left
        case right
        case up
        case down
        case home
        case end
        case clearBeforeCursor
        case clearAfterCursor
        case toggleToolDetails
        case endOfInput
        case cancel
        case unknown
    }

    static let escapeSequenceInitialTimeout: Int32 = 120
    static let escapeSequenceContinuationTimeout: Int32 = 60
    static let bracketedPasteByteTimeout: Int32 = 2000
    static let escapeSequenceMaximumLength = 24
    static let maximumPanelCommandSuggestionLines = 6

    var history: [String] = []
    var historyIndex: Int?
    var draftBeforeHistory: [Character] = []
    let rawInput = TerminalRawInput()
    let panelLock = OSAllocatedUnfairLock()
    var panelTask: Task<Void, Never>?
    var panelStatusBar: TerminalStatusBar?
    var panelBuffer: [Character] = []
    var panelCursorIndex = 0
    var panelIsProcessing = false
    var panelQueuedPromptCount = 0
    var panelOverlayOverride: TerminalPanelModeOverride?
    var panelCommandSuggestions: [TerminalCommandSuggestion] = []
    var panelCommandSuggestionIndex = 0

    public init() {}

    public func readSingleKey(prompt: String) -> String? {
        AgentOutput.standardError.writeString(prompt)

        return rawInput.withRawTerminal {
            while true {
                guard let key = readKey() else {
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }

                switch key {
                case let .character(text):
                    AgentOutput.standardError.writeString("\(text)\n")
                    return text
                case let .paste(text):
                    guard let firstCharacter = text.first else {
                        continue
                    }
                    let value = String(firstCharacter)
                    AgentOutput.standardError.writeString("\(value)\n")
                    return value
                case .enter:
                    AgentOutput.standardError.writeString("\n")
                    return ""
                case .endOfInput:
                    AgentOutput.standardError.writeString("\n")
                    return nil
                default:
                    continue
                }
            }
        }
    }

    public func readLine(prompt: String) -> String? {
        var buffer: [Character] = []
        var cursorIndex = 0
        historyIndex = nil
        draftBeforeHistory.removeAll()

        AgentOutput.standardError.writeString(prompt)

        return rawInput.withRawTerminal {
            while true {
                guard let key = readKey() else {
                    AgentOutput.standardError.writeString("\n")
                    return nil
                }

                switch key {
                case let .character(text), let .paste(text):
                    let characters = Array(text)
                    guard !characters.isEmpty else {
                        continue
                    }
                    buffer.insert(contentsOf: characters, at: cursorIndex)
                    cursorIndex += characters.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .enter:
                    let line = String(buffer)
                    AgentOutput.standardError.writeString("\n")
                    recordHistory(line)
                    return line
                case .newline:
                    buffer.insert("\n", at: cursorIndex)
                    cursorIndex += 1
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .tab:
                    continue
                case .backspace:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.remove(at: cursorIndex - 1)
                    cursorIndex -= 1
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .delete:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.remove(at: cursorIndex)
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .left:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    cursorIndex -= 1
                    AgentOutput.standardError.writeString("\u{1B}[1D")
                case .right:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    cursorIndex += 1
                    AgentOutput.standardError.writeString("\u{1B}[1C")
                case .up:
                    guard let previous = previousHistory(currentBuffer: buffer) else {
                        continue
                    }
                    buffer = previous
                    cursorIndex = buffer.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .down:
                    guard let next = nextHistory() else {
                        continue
                    }
                    buffer = next
                    cursorIndex = buffer.count
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .home:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(cursorIndex)D")
                    cursorIndex = 0
                case .end:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    AgentOutput.standardError.writeString("\u{1B}[\(buffer.count - cursorIndex)C")
                    cursorIndex = buffer.count
                case .clearBeforeCursor:
                    guard cursorIndex > 0 else {
                        continue
                    }
                    buffer.removeSubrange(0..<cursorIndex)
                    cursorIndex = 0
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .clearAfterCursor:
                    guard cursorIndex < buffer.count else {
                        continue
                    }
                    buffer.removeSubrange(cursorIndex..<buffer.count)
                    redraw(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
                case .toggleToolDetails:
                    continue
                case .endOfInput:
                    if buffer.isEmpty {
                        AgentOutput.standardError.writeString("\n")
                        return nil
                    }
                case .cancel:
                    continue
                case .unknown:
                    continue
                }
            }
        }
    }
}
