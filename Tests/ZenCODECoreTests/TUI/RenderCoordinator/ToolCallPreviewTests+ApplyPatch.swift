//
//  ToolCallPreviewTests+ApplyPatch.swift
//  ZenCODE
//
//  The compact tool block of `local.applyPatch` after its live preview: it
//  merges into the preview (only its status row, with the target the patch
//  names, also `(+N more)` for several files) when the tool-call block drew
//  that call alone, and keeps its full block when the block drew several.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatToolCallPreviewTests {
    private static var appliedPatch: DirectAgentToolResult {
        DirectAgentToolResult(output: "Applied patch to 1 file(s)", summary: "Applied patch")
    }

    /// The preview of a `local.applyPatch` call whose `patch` is `patch`;
    /// `ends` closes its tool-call block.
    private func patchPreview(_ patch: String, ends: Bool = true) -> [DirectAgentToolCallPreview] {
        var events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.applyPatch"),
            .parameterStarted(name: "patch"),
            .parameterText(patch),
            .parameterEnded
        ]
        if ends {
            events.append(.ended)
        }
        return events
    }

    /// The `local.applyPatch` call the executor receives after its preview.
    private func patchCall(id: String, patch: String) -> DirectAgentToolCall {
        let arguments = ["patch": patch]
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return presentedToolCall(
            id: id,
            name: "local.applyPatch",
            argumentsObject: arguments,
            argumentsJSON: json
        )
    }

    private func updatePatch(_ path: String) -> String {
        "*** Begin Patch\n*** Update File: \(path)\n@@\n-let x = 0\n+let x = 1\n*** End Patch\n"
    }

    @Test
    func theToolBlockOfAPatchAfterItsPreviewKeepsOnlyItsStatus() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let patch = updatePatch("/tmp/Example.swift")
        let toolCall = patchCall(id: "patch-1", patch: patch)

        await send(patchPreview(patch), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        // The preview header already showed the canonical name.
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        #expect(await renderer.previewMergedToolCallID == toolCall.id)
        await renderer.writeToolCallCompleted(toolCall, result: Self.appliedPatch)

        let shown = terminalScreenText(await renderer.capturedText(on: .standardError), width: columns)
        #expect(shown == [
            "", "", "🛠️  local.applyPatch",
            "*** Begin Patch", "*** Update File: /tmp/Example.swift", "@@",
            "-let x = 0", "+let x = 1", "*** End Patch",
            "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
        #expect(shown.components(separatedBy: "local.applyPatch").count - 1 == 1)
    }

    @Test
    func theMergedBlockOfAPatchOnSeveralFilesKeepsTheirTarget() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let patch = "*** Begin Patch\n*** Update File: /tmp/A.swift\n@@\n-a\n+b\n"
            + "*** Add File: /tmp/B.swift\n+c\n*** End Patch\n"
        let toolCall = patchCall(id: "patch-1", patch: patch)

        await send(patchPreview(patch), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        #expect(await renderer.previewMergedToolCallID == toolCall.id)
        await renderer.writeToolCallCompleted(toolCall, result: Self.appliedPatch)

        let shown = terminalScreenText(await renderer.capturedText(on: .standardError), width: columns)
        #expect(shown.hasSuffix([
            "*** End Patch", "/tmp/A.swift (+1 more) ✅", "", ""
        ].joined(separator: "\n")))
        #expect(shown.components(separatedBy: "local.applyPatch").count - 1 == 1)
    }

    @Test
    func twoPatchesDrawnInOneBlockKeepTheirOwnHeaders() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let first = patchCall(id: "patch-a", patch: updatePatch("/tmp/A.swift"))
        let second = patchCall(id: "patch-b", patch: updatePatch("/tmp/B.swift"))

        // Both calls are drawn before either runs: the preview on screen is
        // the second one's, so neither block merges.
        await send(
            patchPreview(updatePatch("/tmp/A.swift"), ends: false) + patchPreview(updatePatch("/tmp/B.swift")),
            to: renderer
        )
        for call in [first, second] {
            await renderer.writeToolCallStarted(call)
            #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
            #expect(await renderer.previewMergedToolCallID == nil)
            await renderer.writeToolCallCompleted(call, result: Self.appliedPatch)
        }

        let preview = { (path: String) in
            [
                "🛠️  local.applyPatch", "*** Begin Patch", "*** Update File: \(path)", "@@",
                "-let x = 0", "+let x = 1", "*** End Patch"
            ]
        }
        let shown = terminalScreenText(await renderer.capturedText(on: .standardError), width: columns)
        #expect(shown == (["", ""] + preview("/tmp/A.swift") + [""] + preview("/tmp/B.swift") + [
            "", "🛠️  local.applyPatch", "/tmp/A.swift ✅",
            "", "🛠️  local.applyPatch", "/tmp/B.swift ✅", "", ""
        ]).joined(separator: "\n"))
    }
}
