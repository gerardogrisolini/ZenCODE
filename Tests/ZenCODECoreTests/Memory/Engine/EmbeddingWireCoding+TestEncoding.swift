//
//  EmbeddingWireCoding+TestEncoding.swift
//  ZenCODECoreTests
//
//  The version 3 encoding of an embedding vector, which production only
//  decodes: the tests use it to build graph files of that version.
//

import Foundation
@testable import ZenCODECore

extension EmbeddingWireCoding {
    /// The version 3 wire form of `values`: the base64 string of
    /// ``data(from:)``.
    static func string(from values: [Float]) -> String {
        data(from: values).base64EncodedString()
    }

    /// The IEEE-754 binary32 components of `values` in little-endian byte
    /// order.
    static func data(from values: [Float]) -> Data {
        let bits = values.map { $0.bitPattern.littleEndian }
        return bits.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
