//
//  ZenLiveTranscriptCoalescer.swift
//  ZenApp
//
//  Limits visual updates of one streaming block while keeping session state
//  immediate and preserving block boundaries and the end of a turn.
//

import Foundation
import Observation
import ZenAppSession

struct ZenLiveTranscriptInput: Equatable {
    var items: [ZenTranscriptItem]
    var isGenerating: Bool
    var blockID: String?
}

/// The live rows shown by SwiftUI. Tokens of the block already on screen are
/// published at most once per interval; its first version, a different block,
/// and the final update publish immediately. The session itself still applies
/// every snapshot, so no runtime state or transcript content is lost.
@MainActor
@Observable
final class ZenLiveTranscriptCoalescer {
    private(set) var items: [ZenTranscriptItem] = []

    private let interval: Duration
    @ObservationIgnored private var latest = ZenLiveTranscriptInput(items: [], isGenerating: false, blockID: nil)
    @ObservationIgnored private var presentedBlockID: String?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    init(interval: Duration = .milliseconds(33)) {
        self.interval = interval
    }

    func update(_ input: ZenLiveTranscriptInput) {
        latest = input
        guard input.isGenerating,
              input.blockID != nil,
              input.blockID == presentedBlockID
        else {
            flush()
            return
        }
        guard updateTask == nil else { return }
        let interval = interval
        updateTask = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.publishLatest()
        }
    }

    /// Publishes the latest input now, cancelling a deferred update.
    func flush() {
        updateTask?.cancel()
        updateTask = nil
        publishLatest()
    }

    func stop() {
        updateTask?.cancel()
        updateTask = nil
    }

    private func publishLatest() {
        updateTask = nil
        if items != latest.items {
            items = latest.items
        }
        presentedBlockID = latest.blockID
    }
}
