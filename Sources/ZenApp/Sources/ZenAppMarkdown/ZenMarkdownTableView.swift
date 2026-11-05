//
//  ZenMarkdownTableView.swift
//  ZenApp
//
//  GFM tables drawn with `Grid`, with `markdownTableBorder` borders and the
//  header in `markdownTableHeader`.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// A GFM table: bold header, row dividers, column separators and per-column
/// alignment from the delimiter row.
struct ZenMarkdownTableView: View {
    let header: [ZenMarkdownInline]
    let alignments: [ZenMarkdownTableAlignment]
    let rows: [[ZenMarkdownInline]]
    @Environment(\.zenPalette) private var palette

    /// The column count: the widest of the header, the alignments and the rows.
    private var columnCount: Int {
        max(header.count, alignments.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        let columns = columnCount
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                cells(header, columns: columns, isHeader: true)
            }
            divider
            ForEach(rows.indices, id: \.self) { index in
                GridRow {
                    cells(rows[index], columns: columns, isHeader: false)
                }
                if index < rows.count - 1 {
                    divider
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(palette.markdownTableBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A full-width horizontal rule between rows.
    private var divider: some View {
        Rectangle()
            .fill(palette.markdownTableBorder)
            .frame(height: 1)
            .gridCellUnsizedAxes(.horizontal)
    }

    /// The cells of one row, interleaved with vertical separators; missing
    /// cells are empty.
    private func cells(_ row: [ZenMarkdownInline], columns: Int, isHeader: Bool) -> some View {
        ForEach(0..<columns, id: \.self) { column in
            if column > 0 {
                Rectangle()
                    .fill(palette.markdownTableBorder)
                    .frame(width: 1)
                    .gridCellUnsizedAxes(.vertical)
            }
            cell(column < row.count ? row[column] : ZenMarkdownInline(), column: column, isHeader: isHeader)
        }
    }

    private func cell(_ content: ZenMarkdownInline, column: Int, isHeader: Bool) -> some View {
        let alignment = column < alignments.count ? alignments[column] : .none
        return ZenMarkdownText(
            content,
            font: isHeader ? .body.bold() : .body,
            color: isHeader ? palette.markdownTableHeader : nil
        )
        .multilineTextAlignment(Self.textAlignment(alignment))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .gridColumnAlignment(Self.horizontalAlignment(alignment))
    }

    static func horizontalAlignment(_ alignment: ZenMarkdownTableAlignment) -> HorizontalAlignment {
        switch alignment {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }

    static func textAlignment(_ alignment: ZenMarkdownTableAlignment) -> TextAlignment {
        switch alignment {
        case .none, .left: .leading
        case .center: .center
        case .right: .trailing
        }
    }
}
