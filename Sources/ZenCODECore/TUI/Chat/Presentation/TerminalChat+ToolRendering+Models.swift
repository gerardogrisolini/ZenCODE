//
//  TerminalChat+ToolRendering+Models.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension TerminalChat {
    /// A detailed tool row before terminal rendering. Side-by-side diff cells
    /// are kept in separate fields instead of being encoded into the text, so
    /// no byte sequence in the payload — ANSI, Unicode or otherwise — can be
    /// mistaken for the column boundary.
    enum DetailedToolRow: Sendable, Equatable {
        case text(String)
        /// A parameter payload row. `highlightsJSON` is false for rows that only
        /// look like JSON because they sit inside a `"""` block, where the
        /// payload is a raw multi-line string rather than structured data.
        case parameter(String, highlightsJSON: Bool = true)
        case code(DetailedToolCodeLine)
        case diff(DetailedToolDiffCells)
        case unifiedDiff(DetailedToolUnifiedDiffLine)

        /// Marker-free textual projection used for row accounting, wrapping
        /// fallbacks, tests and any non-terminal consumer.
        var plainText: String {
            switch self {
            case let .text(line):
                return line
            case let .parameter(line, _):
                return line
            case let .code(line):
                return line.plainText
            case let .diff(cells):
                return cells.plainText
            case let .unifiedDiff(line):
                return line.plainText
            }
        }
    }

    /// A source row whose gutter stays separate from syntax-highlighted content.
    /// File-read tools can preserve the real line number returned by the tool,
    /// while generated snippets use the same representation with local numbers.
    struct DetailedToolCodeLine: Sendable, Equatable {
        static let gutter = " │ "

        let indentation: String
        let lineNumber: String
        let content: String
        /// The complete logical source line was highlighted before wrapping, so
        /// this fragment already carries the ANSI state active at its boundary.
        var contentIsPreHighlighted = false

        var prefix: String {
            "\(indentation)\(lineNumber)\(Self.gutter)"
        }

        var plainText: String {
            "\(prefix)\(TerminalANSIText.stripANSI(content))"
        }

        var continuation: DetailedToolCodeLine {
            DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: String(repeating: " ", count: lineNumber.count),
                content: content,
                contentIsPreHighlighted: contentIsPreHighlighted
            )
        }
    }

    /// A single side-by-side diff row. Both cells are already padded to the
    /// column width, so the divider position is a layout property instead of
    /// something parsed back out of the content.
    struct DetailedToolDiffCells: Sendable, Equatable {
        static let divider = " │ "

        let indentation: String
        let oldCell: String
        let newCell: String
        /// Both cells were highlighted as complete logical source lines before
        /// they were split into physical rows.
        var cellsArePreHighlighted = false

        var plainText: String {
            "\(indentation)\(TerminalANSIText.stripANSI(oldCell))"
                + "\(Self.divider)\(TerminalANSIText.stripANSI(newCell))"
        }
    }

    /// A single line of the narrow, unified diff presentation. The source
    /// content is kept separate from its diff marker and line-number gutter so
    /// wrapping can retain the visual diff structure without inspecting the
    /// payload for a delimiter.
    struct DetailedToolUnifiedDiffLine: Sendable, Equatable {
        static let gutter = " │ "

        let indentation: String
        /// `-` for a removed line, `+` for an added line, or a space for an
        /// unchanged context line.
        let marker: String
        /// A right-aligned source line number, or an equally wide blank gutter
        /// for an empty payload / wrapped continuation.
        let lineNumber: String
        let content: String
        var contentIsPreHighlighted = false

        var prefix: String {
            "\(indentation)\(marker) \(lineNumber)\(Self.gutter)"
        }

        var plainText: String {
            "\(prefix)\(TerminalANSIText.stripANSI(content))"
        }

        var continuation: DetailedToolUnifiedDiffLine {
            DetailedToolUnifiedDiffLine(
                indentation: indentation,
                marker: marker,
                lineNumber: String(repeating: " ", count: lineNumber.count),
                content: content,
                contentIsPreHighlighted: contentIsPreHighlighted
            )
        }
    }

    /// Layout-ready rows shared by every terminal surface that presents a tool.
    /// The coordinator owns lifecycle/redraw policy, while this value keeps the
    /// compact prefix and optional source appendix byte-for-byte consistent.
    struct ToolPresentationRows: Sendable, Equatable {
        var compactRows: [DetailedToolRow]
        var detailRows: [DetailedToolRow]
        /// The same safe width used to wrap the source rows. Background fill
        /// must stop here rather than extending into the terminal's right inset.
        let detailContentWidth: Int

        var allRows: [DetailedToolRow] {
            compactRows + detailRows
        }
    }
}
