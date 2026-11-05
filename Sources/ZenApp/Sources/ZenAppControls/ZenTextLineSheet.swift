//
//  ZenTextLineSheet.swift
//  ZenApp
//
//  The sheet of a `readLine(prompt:)` request.
//

import Foundation
import SwiftUI
import ZenAppTheme
import ZenCODECore

/// A sheet asking the operator for one line of text: the prompt, a field,
/// OK (Return) and Cancel (Esc). It answers once: the text, or `nil` when
/// cancelled.
public struct ZenTextLineSheet: View {
    @Environment(\.zenPalette) private var palette
    private let prompt: String
    private let onAnswer: @MainActor (String?) -> Void

    @State private var text = ""
    @State private var hasAnswered = false
    @FocusState private var isFieldFocused: Bool

    public init(
        prompt: String,
        initialText: String = "",
        onAnswer: @escaping @MainActor (String?) -> Void
    ) {
        self.prompt = prompt
        self._text = State(initialValue: initialText)
        self.onAnswer = onAnswer
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(prompt)
                .font(.headline)
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Answer", text: $text)
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(ZenFonts.mono)
                .foregroundStyle(palette.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
                .focused($isFieldFocused)
                .onSubmit { answer(text) }
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) {
                    answer(nil)
                }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
                Button("OK") {
                    answer(text)
                }
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480)
        .onAppear { isFieldFocused = true }
    }

    private func answer(_ value: String?) {
        guard !hasAnswered else { return }
        hasAnswered = true
        onAnswer(value)
    }
}

#Preview("Text line") {
    ZenTextLineSheet(prompt: "Session name:", onAnswer: { _ in })
}
