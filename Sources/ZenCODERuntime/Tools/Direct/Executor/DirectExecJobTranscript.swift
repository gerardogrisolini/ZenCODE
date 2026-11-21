//
//  DirectExecJobTranscript.swift
//  ZenCODE
//
//  Lock-protected, bounded transcript of the interleaved output of one
//  background job.
//

import FeatureKit
import Foundation
import Synchronization
import ToolCore

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// Accumulates interleaved stdout/stderr output for one background job.
/// Appended from pipe readability handlers (dispatch queues) and read from
/// the runtime actor, so access is lock-protected. Retains a bounded tail of
/// the transcript; earlier bytes are dropped but remain accounted for so poll
/// offsets stay stable.
final class DirectExecJobTranscript: Sendable {
    struct Snapshot: Sendable {
        let text: String
        let nextOffset: Int
        let outputWasDropped: Bool
    }

    private struct State: Sendable {
        var data = Data()
        var droppedBytes = 0
    }

    private let state = Mutex(State())
    private let maxRetainedBytes: Int

    init(maxRetainedBytes: Int) {
        self.maxRetainedBytes = max(maxRetainedBytes, 1)
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else {
            return
        }
        state.withLock { state in
            state.data.append(chunk)
            if state.data.count > maxRetainedBytes {
                let overflow = state.data.count - maxRetainedBytes
                state.data = Data(state.data.dropFirst(overflow))
                state.droppedBytes += overflow
            }
        }
    }

    /// Returns the transcript text at or after `offset` (a byte offset into
    /// the job's full output), the next offset to poll from, and whether any
    /// requested bytes were already dropped from the retained tail.
    func read(from offset: Int) -> Snapshot {
        state.withLock { state in
            let total = state.droppedBytes + state.data.count
            let clamped = min(max(offset, 0), total)
            let outputWasDropped = clamped < state.droppedBytes
            let localStart = max(clamped - state.droppedBytes, 0)
            let chunk = Data(state.data.dropFirst(localStart))
            return Snapshot(
                text: String(decoding: chunk, as: UTF8.self),
                nextOffset: total,
                outputWasDropped: outputWasDropped
            )
        }
    }
}
