//
//  ZenComposer+Accessories.swift
//  ZenApp
//
//  The accessory views of the prompt composer: the queued prompt chips above
//  the field and the key hint under it.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

extension ZenComposer {
    /// The key hint, under the field's text, on one line: its compact form
    /// when the full one does not fit, as in the terminal.
    func keyHint(_ hint: ZenComposerLogic.KeyHint) -> some View {
        keyHintText(hint)
            .font(.caption)
            .foregroundStyle(palette.textMuted)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, attachButtonWidth + Self.rowSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func keyHintText(_ hint: ZenComposerLogic.KeyHint) -> some View {
        if let compact = hint.compact {
            ViewThatFits(in: .horizontal) {
                Text(hint.full)
                Text(compact)
            }
        } else {
            Text(hint.full)
        }
    }

    var queuedChips: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(queued) { item in
                    queuedChip(item)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func queuedChip(_ item: ZenComposerQueuedItem) -> some View {
        HStack(spacing: 6) {
            Text("queued")
                .foregroundStyle(palette.statusQueued)
            Text(ZenComposerLogic.chipText(item.text))
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 240, alignment: .leading)
            Button {
                actions.removeQueued(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.textMuted)
            .help("Remove from the queue")
            .accessibilityLabel("Remove queued prompt")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular.tint(palette.statusQueued.opacity(0.15)), in: .capsule)
    }
}
