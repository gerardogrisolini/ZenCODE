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
@testable import ZenCODERuntime

@Suite
struct DS4UTF8StreamDecoderTests {
    @Test
    func everyByteSplitReassemblesWithoutReplacement() {
        let text = "Perché 漢字 🙂👍🏽 é\u{301} <｜DSML｜invoke>"
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            var decoder = DS4UTF8StreamDecoder()
            let first = Array(bytes[..<split]).withUnsafeBufferPointer { decoder.consume($0) }
            let second = Array(bytes[split...]).withUnsafeBufferPointer { decoder.consume($0) }
            let tail = decoder.finish()
            #expect(first + second + tail == text, "split at \(split)")
            #expect(!(first + second).contains("\u{FFFD}"), "split at \(split)")
            #expect(tail.isEmpty, "split at \(split)")
        }
    }

    @Test
    func finishFlushesIncompleteScalarWithReplacement() {
        var decoder = DS4UTF8StreamDecoder()
        let bytes = Array("a🙂".utf8)
        let consumed = Array(bytes.dropLast()).withUnsafeBufferPointer { decoder.consume($0) }
        #expect(consumed == "a")
        #expect(decoder.hasPendingBytes)
        #expect(decoder.finish() == "\u{FFFD}")
        #expect(!decoder.hasPendingBytes)
    }

    @Test
    func invalidBytesAreFlushedOnceMoreThanThreeArePending() {
        var decoder = DS4UTF8StreamDecoder()
        // A stray continuation byte can never start a scalar: once more than
        // 3 bytes are held the decoder gives up buffering and replaces it.
        let held = [UInt8]([0x80, 0x41]).withUnsafeBufferPointer { decoder.consume($0) }
        #expect(held == "")
        let flushed = [UInt8]([0x42, 0x43]).withUnsafeBufferPointer { decoder.consume($0) }
        #expect(flushed == "\u{FFFD}ABC")
        #expect(!decoder.hasPendingBytes)
    }
}
