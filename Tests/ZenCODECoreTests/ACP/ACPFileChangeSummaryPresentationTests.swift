//
//  ACPFileChangeSummaryPresentationTests.swift
//  ZenCODE
//
//  ACP does not present the final file-change summary of a turn.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// Recording sink: captures every wire message in delivery order.
private final class SummaryRecordingSink: Sendable {
    private let storage = Mutex<[String]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            storage.withLock { $0.append(String(decoding: data, as: UTF8.self)) }
        }
    }

    func deliveredMessages() -> [String] {
        storage.withLock { $0 }
    }
}

@Suite
struct ACPFileChangeSummaryPresentationTests {
    @Test
    func fileChangeSummaryDoesNotReachTheWire() async {
        let recorder = SummaryRecordingSink()
        let presenter = ACPPromptPresenter(
            sessionID: "summary-session",
            workspaceURL: URL(fileURLWithPath: "/tmp/workspace", isDirectory: true),
            writer: ACPWriter(sink: recorder.sink),
            updatePipeline: nil,
            ensureTasklessObserver: {},
            claimDelegatedToolNotification: { _ in true }
        )
        let summary = TurnFileChangeSummary(entries: [
            .init(
                path: "Sources/App.swift",
                additions: 3,
                deletions: 1,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            ),
        ])

        await presenter.presentAssistantContent("Done.")
        await presenter.presentFileChangeSummary(summary)

        let messages = recorder.deliveredMessages()
        #expect(messages.count == 1)
        #expect(messages.first?.contains("Done.") == true)
        #expect(!messages.contains { $0.contains("Summary:") })
        #expect(!messages.contains { $0.contains("Sources/App.swift") })
    }
}
