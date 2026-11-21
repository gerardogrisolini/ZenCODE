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
package enum TerminalStyle {
    package static let reset = sequence(0)

    package enum Attribute {
        package static let bold = TerminalStyle.sequence(1)
        package static let italic = TerminalStyle.sequence(3)
        package static let strikethrough = TerminalStyle.sequence(9)
    }

    package enum Text {
        package static let primary = TerminalStyle.sequence(97)
        package static let secondary = TerminalStyle.sequence(38, 5, 253)
        package static let muted = TerminalStyle.sequence(90)
        static let subtle = TerminalStyle.sequence(38, 5, 250)
        package static let systemMessage = TerminalStyle.sequence(38, 5, 110)
        package static let operationalMessage = TerminalStyle.sequence(38, 5, 75)
        package static let failureMessage = TerminalStyle.sequence(38, 5, 203)
    }

    package enum Accent {
        package static let primary = TerminalStyle.sequence(38, 5, 208)
        static let count = TerminalStyle.sequence(38, 5, 81)
    }

    package enum Status {
        static let queued = TerminalStyle.sequence(33)
        package static let active = Accent.primary
        static let success = TerminalStyle.sequence(32)
        package static let failure = TerminalStyle.sequence(31)
        static let inactive = Text.muted
    }

    package enum FileChange {
        package static let summaryHeader = Accent.primary
        package static let count = Accent.count
        package static let metadata = TerminalStyle.sequence(38, 5, 244)
        package static let addition = TerminalStyle.sequence(38, 5, 114)
        package static let deletion = TerminalStyle.sequence(38, 5, 203)
        package static let path = Text.primary
        package static let binary = metadata
        package static let hint = Text.subtle
    }

    enum Surface {
        static let darkBackground = TerminalStyle.sequence(48, 5, 236)
    }

    package enum Tool {
        package static let title = Accent.primary
        package static let label = TerminalStyle.sequence(38, 5, 173)
        package static let value = TerminalStyle.sequence(38, 5, 215)
        package static let parameter = Text.subtle
        package static let duration = Text.muted
        package static let codeGutter = Text.muted
        package static let codeBackground = Surface.darkBackground
    }

    package enum SharedChat {
        package struct Palette: Equatable, Sendable {
            package let border: String
            package let title: String
            package let body: String
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

        package static func palette(for appearance: TerminalMarkdownPalette.Appearance) -> Palette {
            switch appearance {
            case .dark:
                return darkPalette
            case .light:
                return lightPalette
            }
        }
    }

    package enum Chrome {
        // Dim the prompt/status frame, clearing inherited bold before SGR 2.
        package static let promptBorder = TerminalStyle.sequence(22, 2, 38, 5, 208)
        // Command menus share the prompt's dimmed frame; only the frame is
        // dimmed, the menu content keeps its full intensity.
        package static let border = promptBorder
        // A darker orange (xterm-256 130) without SGR 2, so the logo's
        // brightness does not depend on how each terminal renders faint text;
        // SGR 22 still clears inherited bold.
        package static let startupLogo = TerminalStyle.sequence(22, 38, 5, 130)
        package static let suggestion = Text.muted
    }

    package enum Permission {
        // Dimmed frame in the same light blue as the choice keys, clearing
        // inherited bold before SGR 2, so the consent card reads translucent
        // next to the prompt frame.
        package static let border = TerminalStyle.sequence(22, 2, 38, 5, 81)
        // The title embedded in the top border matches the command marker's
        // orange at full intensity; SGR 22 clears the frame's dim attribute.
        package static let title = TerminalStyle.sequence(22, 38, 5, 208)
        // The command marker keeps the full identity orange to stay prominent.
        package static let marker = Accent.primary
        package static let choice = TerminalStyle.sequence(38, 5, 81)
        package static let emphasizedChoice = TerminalStyle.sequence(1, 38, 5, 81)
        package static let metadata = TerminalStyle.sequence(38, 5, 244)
    }

    package enum Prompt {
        package static let background = Surface.darkBackground
        package static let turnSeparator = Text.muted
    }

    package enum Thinking {
        package static let title = TerminalStyle.sequence(bodyCode)
        package static let bodyCode = 90
        package static let body = TerminalStyle.sequence(bodyCode)

        /// Returns the desaturated xterm-256 accent used while rendering a
        /// thinking stream, or `nil` when the body color should be used.
        package static func mutedAccent(for color: Int) -> Int? {
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

    package enum Markdown {
        package static let dim = Text.muted
        package static let bullet = TerminalStyle.sequence(38, 5, 244)
        package static let link = TerminalStyle.sequence(38, 5, 75)
        package static let quoteBar = TerminalStyle.sequence(38, 5, 108)
        package static let tableBorder = TerminalStyle.sequence(38, 5, 240)
        package static let tableHeader = TerminalStyle.sequence(1, 38, 5, 81)

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
            diffAdditionBackground: TerminalStyle.sequence(48, 2, 30, 48, 36),
            diffRemovalBackground: TerminalStyle.sequence(48, 2, 55, 32, 35),
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
            diffAdditionBackground: TerminalStyle.sequence(48, 5, 194),
            diffRemovalBackground: TerminalStyle.sequence(48, 5, 224),
            diffHunk: TerminalStyle.sequence(1, 38, 5, 25),
            diffHeader: TerminalStyle.sequence(38, 5, 94)
        )
    }

    static func sequence(_ codes: Int...) -> String {
        sequence(codes: codes)
    }

    package static func sequence(codes: [Int]) -> String {
        "\u{1B}[\(codes.map(String.init).joined(separator: ";"))m"
    }
}
