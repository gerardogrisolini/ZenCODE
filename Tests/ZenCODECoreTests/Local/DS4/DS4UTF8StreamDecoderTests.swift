//
//  DS4UTF8StreamDecoderTests.swift
//  ZenCODE
//
//  Ported from abd128942 Tests/ZenCODEDS4Tests/DS4TranscriptSplitterTests.swift
//  (utf8StreamDecoderBuffersSplitScalars) plus every-split and invalid-byte
//  coverage.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DS4UTF8StreamDecoderTests {
    @Test
    func buffersSplitScalars() {
        var decoder = DS4UTF8StreamDecoder()
        let bytes = Array("ciao 🙂".utf8)
        let splitIndex = bytes.count - 2

        let first = decoder.consume(Array(bytes[..<splitIndex]))
        let second = decoder.consume(Array(bytes[splitIndex...]))

        #expect(first == "ciao ")
        #expect(second == "🙂")
        #expect(first + second + decoder.finish() == "ciao 🙂")
        #expect(!first.contains("\u{FFFD}"))
        #expect(!second.contains("\u{FFFD}"))
    }

    @Test
    func everyByteSplitReassemblesWithoutReplacement() {
        let text = "Perché 漢字 🙂👍🏽 é\u{301} <｜DSML｜invoke>"
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            var decoder = DS4UTF8StreamDecoder()
            let first = decoder.consume(Array(bytes[..<split]))
            let second = decoder.consume(Array(bytes[split...]))
            let tail = decoder.finish()
            #expect(first + second + tail == text, "split at \(split)")
            #expect(!(first + second).contains("\u{FFFD}"), "split at \(split)")
            #expect(tail.isEmpty, "split at \(split)")
        }
    }

    @Test
    func singleByteChunksEmitEmptyStringsUntilScalarCompletes() {
        var decoder = DS4UTF8StreamDecoder()
        let outputs = Array("🙂".utf8).map { decoder.consume([$0]) }
        #expect(outputs == ["", "", "", "🙂"])
        #expect(!decoder.hasPendingBytes)
    }

    @Test
    func emptyChunkProducesNothing() {
        var decoder = DS4UTF8StreamDecoder()
        #expect(decoder.consume([]).isEmpty)
        #expect(decoder.finish().isEmpty)
    }

    @Test
    func finishFlushesIncompleteScalarWithReplacement() {
        var decoder = DS4UTF8StreamDecoder()
        let bytes = Array("a🙂".utf8)
        #expect(decoder.consume(Array(bytes.dropLast())) == "a")
        #expect(decoder.hasPendingBytes)
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(!decoder.hasPendingBytes)
    }

    @Test
    func invalidBytesAreFlushedOnceMoreThanThreeArePending() {
        var decoder = DS4UTF8StreamDecoder()
        // A stray continuation byte can never start a scalar: once more than
        // 3 bytes are held the decoder gives up buffering and replaces it.
        #expect(decoder.consume([0x80, 0x41]) == "")
        let flushed = decoder.consume([0x42, 0x43])
        #expect(flushed == "\u{FFFD}ABC")
        #expect(!decoder.hasPendingBytes)
    }
}
