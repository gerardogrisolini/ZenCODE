//
//  TerminalStyle.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/08/26.
//

/// Central source of ANSI styling used by the terminal UI.
///
/// Only Select Graphic Rendition (SGR) sequences belong here. Terminal control
/// commands for cursor movement, line clearing, scroll regions, and input
/// protocols remain next to the code that performs those operations.
enum TerminalStyle {
    static let reset = sequence(0)

    enum Attribute {
        static let bold = TerminalStyle.sequence(1)
        static let italic = TerminalStyle.sequence(3)
        static let strikethrough = TerminalStyle.sequence(9)
    }

    enum Text {
        static let primary = TerminalStyle.sequence(97)
        static let secondary = TerminalStyle.sequence(38, 5, 253)
        static let muted = TerminalStyle.sequence(90)
        static let subtle = TerminalStyle.sequence(38, 5, 250)
        static let systemMessage = TerminalStyle.sequence(38, 5, 110)
        static let operationalMessage = TerminalStyle.sequence(38, 5, 75)
        static let failureMessage = TerminalStyle.sequence(38, 5, 203)
    }

    enum Accent {
        static let primary = TerminalStyle.sequence(38, 5, 208)
        static let count = TerminalStyle.sequence(38, 5, 81)
    }

    enum Status {
        static let queued = TerminalStyle.sequence(33)
        static let active = Accent.primary
        static let success = TerminalStyle.sequence(32)
        static let failure = TerminalStyle.sequence(31)
        static let inactive = Text.muted
    }

    enum FileChange {
        static let summaryHeader = Accent.primary
        static let count = Accent.count
        static let metadata = TerminalStyle.sequence(38, 5, 244)
        static let hunk = TerminalStyle.sequence(38, 5, 141)
        static let addition = TerminalStyle.sequence(38, 5, 114)
        static let deletion = TerminalStyle.sequence(38, 5, 203)
        static let path = Text.primary
        static let binary = metadata
        static let hint = Text.subtle
    }

    enum Surface {
        static let darkBackground = TerminalStyle.sequence(48, 5, 236)
    }

    enum Tool {
        static let title = Accent.primary
        static let label = TerminalStyle.sequence(38, 5, 173)
        static let value = TerminalStyle.sequence(38, 5, 215)
        static let parameter = Text.subtle
        static let duration = Text.muted
        static let codeGutter = Text.muted
        static let codeBackground = Surface.darkBackground
    }

    enum SharedChat {
        struct Palette: Equatable, Sendable {
            let border: String
            let title: String
            let body: String
        }

        /// A desaturated slate blue keeps the reader visually distinct from the
        /// orange application chrome without competing for attention: transient
        /// agent-to-agent traffic stays visible but quieter than system
        /// messages. `22` in the border sequence explicitly disables the
        /// title's bold attribute.
        static let darkPalette = Palette(
            border: TerminalStyle.sequence(22, 38, 5, 60),
            title: TerminalStyle.sequence(1, 38, 5, 66),
            body: Text.secondary
        )
        static let lightPalette = Palette(
            border: TerminalStyle.sequence(22, 38, 5, 59),
            title: TerminalStyle.sequence(1, 38, 5, 59),
            body: TerminalStyle.sequence(38, 5, 235)
        )

        static func palette(for appearance: TerminalMarkdownPalette.Appearance) -> Palette {
            switch appearance {
            case .dark:
                return darkPalette
            case .light:
                return lightPalette
            }
        }
    }

    enum Chrome {
        static let border = Accent.primary
        static let suggestion = Text.muted
    }

    enum Permission {
        static let border = Accent.primary
        static let choice = TerminalStyle.sequence(38, 5, 81)
        static let emphasizedChoice = TerminalStyle.sequence(1, 38, 5, 81)
        static let metadata = TerminalStyle.sequence(38, 5, 244)
    }

    enum Prompt {
        static let background = Surface.darkBackground
        static let turnSeparator = Text.muted
    }

    enum Thinking {
        static let title = TerminalStyle.sequence(bodyCode)
        static let bodyCode = 90
        static let body = TerminalStyle.sequence(bodyCode)

        /// Returns the desaturated xterm-256 accent used while rendering a
        /// thinking stream, or `nil` when the body color should be used.
        static func mutedAccent(for color: Int) -> Int? {
            switch color {
            case 81, 75, 111, 110, 109, 117:
                return 109
            case 180, 222, 144:
                return 144
            case 108:
                return 108
            default:
                return nil
            }
        }
    }

    enum Markdown {
        static let dim = Text.muted
        static let bullet = TerminalStyle.sequence(38, 5, 244)
        static let link = TerminalStyle.sequence(38, 5, 75)
        static let quoteBar = TerminalStyle.sequence(38, 5, 108)
        static let tableBorder = TerminalStyle.sequence(38, 5, 240)
        static let tableHeader = TerminalStyle.sequence(1, 38, 5, 81)

        static let darkPalette = TerminalMarkdownPalette(
            appearance: .dark,
            inlineCodeForeground: TerminalStyle.sequence(38, 5, 180),
            inlineCodeBackground: TerminalStyle.sequence(48, 5, 236),
            codeForeground: TerminalStyle.sequence(38, 5, 252),
            codeBackground: TerminalStyle.sequence(48, 5, 236),
            codeHeaderForeground: TerminalStyle.sequence(1, 38, 5, 117),
            codeHeaderBackground: TerminalStyle.sequence(48, 5, 238),
            headingStyles: [
                TerminalStyle.sequence(1, 38, 5, 81),
                TerminalStyle.sequence(1, 38, 5, 75),
                TerminalStyle.sequence(1, 38, 5, 111),
                TerminalStyle.sequence(38, 5, 111),
                TerminalStyle.sequence(38, 5, 110),
                TerminalStyle.sequence(38, 5, 109)
            ],
            syntaxKeyword: TerminalStyle.sequence(38, 5, 141),
            syntaxType: TerminalStyle.sequence(38, 5, 81),
            syntaxString: TerminalStyle.sequence(38, 5, 114),
            syntaxComment: TerminalStyle.sequence(38, 5, 244),
            syntaxNumber: TerminalStyle.sequence(38, 5, 215),
            syntaxAttribute: TerminalStyle.sequence(38, 5, 214),
            syntaxFunction: TerminalStyle.sequence(38, 5, 117),
            syntaxProperty: TerminalStyle.sequence(38, 5, 109),
            diffAddition: TerminalStyle.sequence(38, 5, 114),
            diffRemoval: TerminalStyle.sequence(38, 5, 210),
            diffHunk: TerminalStyle.sequence(1, 38, 5, 81),
            diffHeader: TerminalStyle.sequence(38, 5, 180)
        )

        static let lightPalette = TerminalMarkdownPalette(
            appearance: .light,
            inlineCodeForeground: TerminalStyle.sequence(38, 5, 94),
            inlineCodeBackground: TerminalStyle.sequence(48, 5, 254),
            codeForeground: TerminalStyle.sequence(38, 5, 235),
            codeBackground: TerminalStyle.sequence(48, 5, 254),
            codeHeaderForeground: TerminalStyle.sequence(1, 38, 5, 25),
            codeHeaderBackground: TerminalStyle.sequence(48, 5, 252),
            headingStyles: [
                TerminalStyle.sequence(1, 38, 5, 25),
                TerminalStyle.sequence(1, 38, 5, 31),
                TerminalStyle.sequence(1, 38, 5, 61),
                TerminalStyle.sequence(38, 5, 61),
                TerminalStyle.sequence(38, 5, 60),
                TerminalStyle.sequence(38, 5, 59)
            ],
            syntaxKeyword: TerminalStyle.sequence(38, 5, 90),
            syntaxType: TerminalStyle.sequence(38, 5, 24),
            syntaxString: TerminalStyle.sequence(38, 5, 28),
            syntaxComment: TerminalStyle.sequence(38, 5, 242),
            syntaxNumber: TerminalStyle.sequence(38, 5, 130),
            syntaxAttribute: TerminalStyle.sequence(38, 5, 130),
            syntaxFunction: TerminalStyle.sequence(38, 5, 25),
            syntaxProperty: TerminalStyle.sequence(38, 5, 30),
            diffAddition: TerminalStyle.sequence(38, 5, 28),
            diffRemoval: TerminalStyle.sequence(38, 5, 124),
            diffHunk: TerminalStyle.sequence(1, 38, 5, 25),
            diffHeader: TerminalStyle.sequence(38, 5, 94)
        )
    }

    static func sequence(_ codes: Int...) -> String {
        sequence(codes: codes)
    }

    static func sequence(codes: [Int]) -> String {
        "\u{1B}[\(codes.map(String.init).joined(separator: ";"))m"
    }
}
