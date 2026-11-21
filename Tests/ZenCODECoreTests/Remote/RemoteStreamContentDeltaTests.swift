//
//  RemoteStreamContentDeltaTests.swift
//  ZenCODE
//
//  Direct tests of `RemoteStreamAccumulator.streamContentDelta`: how a full
//  text snapshot is reconciled with the text already emitted by the deltas,
//  including snapshots that differ from it only by whitespace.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite
struct RemoteStreamContentDeltaTests {
    private func delta(snapshot: String, accumulated: String) -> String {
        RemoteStreamAccumulator.streamContentDelta(
            fromSnapshot: snapshot,
            accumulatedText: accumulated
        )
    }

    @Test
    func equalSnapshotYieldsNothing() {
        #expect(delta(snapshot: "Hello", accumulated: "Hello") == "")
    }

    @Test
    func exactExtensionYieldsTheRemainder() {
        #expect(delta(snapshot: "Hello world", accumulated: "Hello") == " world")
    }

    @Test
    func exactSuffixYieldsNothing() {
        #expect(delta(snapshot: "world", accumulated: "Hello world") == "")
    }

    @Test
    func trailingNewlineInAccumulatedTextYieldsNothing() {
        #expect(delta(snapshot: "Hai ragione.", accumulated: "Hai ragione.\n") == "")
    }

    @Test
    func snapshotWithDifferentInnerWhitespaceYieldsNothing() {
        #expect(delta(snapshot: "AB", accumulated: "A\nB") == "")
        #expect(delta(snapshot: "Hello world", accumulated: "Hello  world") == "")
        #expect(delta(snapshot: "Hello  world", accumulated: "Hello\nworld") == "")
    }

    @Test
    func extensionWithWhitespaceDifferenceYieldsOnlyTheNewText() {
        #expect(delta(snapshot: "Hello world", accumulated: "Hello\n") == "world")
        #expect(delta(snapshot: "A B C", accumulated: "A  B") == " C")
    }

    @Test
    func partialOverlapIsStillTrimmed() {
        #expect(delta(snapshot: "world!", accumulated: "Hello wor") == "ld!")
    }

    @Test
    func unrelatedSnapshotIsReturnedWhole() {
        #expect(delta(snapshot: "Goodbye", accumulated: "Hello") == "Goodbye")
    }

    @Test
    func whitespaceOnlySnapshotIsNotTreatedAsAlreadyShown() {
        #expect(delta(snapshot: " ", accumulated: "Hello") == " ")
    }

    @Test
    func emptyAccumulatedTextReturnsTheSnapshot() {
        #expect(delta(snapshot: "Hello", accumulated: "") == "Hello")
    }
}
