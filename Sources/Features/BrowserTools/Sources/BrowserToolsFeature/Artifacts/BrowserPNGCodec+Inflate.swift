//
//  BrowserPNGCodec+Inflate.swift
//  BrowserToolsFeature
//
//  Bounded zlib/DEFLATE decoding used by BrowserPNGCodec.
//

import Foundation

extension BrowserPNGCodec {
    static func inflateZlib(_ compressed: [UInt8], maximumOutputBytes: Int) throws -> [UInt8] {
        guard compressed.count >= 6 else { throw BrowserPNGCodecError.invalidZlibStream }
        let cmf = compressed[0]
        let flags = compressed[1]
        let header = (Int(cmf) << 8) | Int(flags)
        guard cmf & 0x0F == 8,
              cmf >> 4 <= 7,
              header.isMultiple(of: 31),
              flags & 0x20 == 0
        else {
            throw BrowserPNGCodecError.invalidZlibStream
        }

        let deflateEnd = compressed.count - 4
        let deflateBytes = Array(compressed[2..<deflateEnd])
        var reader = DeflateBitReader(bytes: deflateBytes)
        var output = [UInt8]()
        output.reserveCapacity(min(maximumOutputBytes, 1_024 * 1_024))
        var finalBlock = false
        var blockCount = 0

        repeat {
            try Task.checkCancellation()
            blockCount += 1
            guard blockCount <= maximumDeflateBlocks else { throw BrowserPNGCodecError.invalidDeflateStream }
            finalBlock = try reader.readBits(1) == 1
            let blockType = try reader.readBits(2)
            switch blockType {
            case 0:
                try inflateStoredBlock(reader: &reader, output: &output, maximumOutputBytes: maximumOutputBytes)
            case 1:
                let trees = try fixedHuffmanTrees()
                try inflateHuffmanBlock(
                    reader: &reader,
                    literalLengthTree: trees.literalLength,
                    distanceTree: trees.distance,
                    output: &output,
                    maximumOutputBytes: maximumOutputBytes
                )
            case 2:
                let trees = try dynamicHuffmanTrees(reader: &reader)
                try inflateHuffmanBlock(
                    reader: &reader,
                    literalLengthTree: trees.literalLength,
                    distanceTree: trees.distance,
                    output: &output,
                    maximumOutputBytes: maximumOutputBytes
                )
            default:
                throw BrowserPNGCodecError.invalidDeflateStream
            }
        } while !finalBlock

        reader.alignToByte()
        guard reader.isAtEnd else { throw BrowserPNGCodecError.invalidDeflateStream }

        let expectedAdler = (UInt32(compressed[deflateEnd]) << 24)
            | (UInt32(compressed[deflateEnd + 1]) << 16)
            | (UInt32(compressed[deflateEnd + 2]) << 8)
            | UInt32(compressed[deflateEnd + 3])
        guard adler32(output) == expectedAdler else { throw BrowserPNGCodecError.invalidZlibStream }
        return output
    }

    fileprivate static func inflateStoredBlock(
        reader: inout DeflateBitReader,
        output: inout [UInt8],
        maximumOutputBytes: Int
    ) throws {
        reader.alignToByte()
        let length = try reader.readAlignedUInt16()
        let complement = try reader.readAlignedUInt16()
        guard length ^ complement == 0xFFFF else { throw BrowserPNGCodecError.invalidDeflateStream }
        guard length <= maximumOutputBytes - output.count else { throw BrowserPNGCodecError.decompressedDataTooLarge }
        let bytes = try reader.readAlignedBytes(count: length)
        output.append(contentsOf: bytes)
    }

    fileprivate static func fixedHuffmanTrees() throws -> (literalLength: DeflateHuffmanTree, distance: DeflateHuffmanTree) {
        var literalLengths = [Int](repeating: 0, count: 288)
        for symbol in 0...143 { literalLengths[symbol] = 8 }
        for symbol in 144...255 { literalLengths[symbol] = 9 }
        for symbol in 256...279 { literalLengths[symbol] = 7 }
        for symbol in 280...287 { literalLengths[symbol] = 8 }
        let distanceLengths = [Int](repeating: 5, count: 32)
        return (try DeflateHuffmanTree(lengths: literalLengths), try DeflateHuffmanTree(lengths: distanceLengths))
    }

    fileprivate static func dynamicHuffmanTrees(
        reader: inout DeflateBitReader
    ) throws -> (literalLength: DeflateHuffmanTree, distance: DeflateHuffmanTree) {
        let literalLengthCount = try reader.readBits(5) + 257
        let distanceCount = try reader.readBits(5) + 1
        let codeLengthCount = try reader.readBits(4) + 4
        guard literalLengthCount <= 286, distanceCount <= 32, codeLengthCount <= 19 else {
            throw BrowserPNGCodecError.invalidDeflateStream
        }

        let codeLengthOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengthLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeLengthCount {
            codeLengthLengths[codeLengthOrder[index]] = try reader.readBits(3)
        }
        let codeLengthTree = try DeflateHuffmanTree(lengths: codeLengthLengths)

        let totalCount = literalLengthCount + distanceCount
        var lengths = [Int]()
        lengths.reserveCapacity(totalCount)
        while lengths.count < totalCount {
            let symbol = try codeLengthTree.decode(reader: &reader)
            switch symbol {
            case 0...15:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw BrowserPNGCodecError.invalidDeflateStream }
                let repeatCount = try reader.readBits(2) + 3
                guard repeatCount <= totalCount - lengths.count else { throw BrowserPNGCodecError.invalidDeflateStream }
                lengths.append(contentsOf: repeatElement(previous, count: repeatCount))
            case 17:
                let repeatCount = try reader.readBits(3) + 3
                guard repeatCount <= totalCount - lengths.count else { throw BrowserPNGCodecError.invalidDeflateStream }
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            case 18:
                let repeatCount = try reader.readBits(7) + 11
                guard repeatCount <= totalCount - lengths.count else { throw BrowserPNGCodecError.invalidDeflateStream }
                lengths.append(contentsOf: repeatElement(0, count: repeatCount))
            default:
                throw BrowserPNGCodecError.invalidDeflateStream
            }
        }

        let literalLengths = Array(lengths[0..<literalLengthCount])
        let distanceLengths = Array(lengths[literalLengthCount..<totalCount])
        guard literalLengths.count > 256, literalLengths[256] != 0 else { throw BrowserPNGCodecError.invalidDeflateStream }
        return (
            try DeflateHuffmanTree(lengths: literalLengths),
            try DeflateHuffmanTree(lengths: distanceLengths, allowsEmpty: true)
        )
    }

    fileprivate static func inflateHuffmanBlock(
        reader: inout DeflateBitReader,
        literalLengthTree: DeflateHuffmanTree,
        distanceTree: DeflateHuffmanTree,
        output: inout [UInt8],
        maximumOutputBytes: Int
    ) throws {
        let lengthBases = [
            3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27,
            31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258,
        ]
        let lengthExtraBits = [
            0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2,
            2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
        ]
        let distanceBases = [
            1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129,
            193, 257, 385, 513, 769, 1_025, 1_537, 2_049, 3_073, 4_097,
            6_145, 8_193, 12_289, 16_385, 24_577,
        ]
        let distanceExtraBits = [
            0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6,
            6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
        ]

        var symbolsProcessed = 0
        while true {
            if symbolsProcessed.isMultiple(of: 4096) {
                try Task.checkCancellation()
            }
            symbolsProcessed += 1
            let symbol = try literalLengthTree.decode(reader: &reader)
            switch symbol {
            case 0...255:
                guard output.count < maximumOutputBytes else { throw BrowserPNGCodecError.decompressedDataTooLarge }
                output.append(UInt8(symbol))
            case 256:
                return
            case 257...285:
                let lengthIndex = symbol - 257
                let length = lengthBases[lengthIndex] + (try reader.readBits(lengthExtraBits[lengthIndex]))
                let distanceSymbol = try distanceTree.decode(reader: &reader)
                guard distanceSymbol < distanceBases.count else { throw BrowserPNGCodecError.invalidDeflateStream }
                let distance = distanceBases[distanceSymbol]
                    + (try reader.readBits(distanceExtraBits[distanceSymbol]))
                guard distance > 0, distance <= output.count,
                      length <= maximumOutputBytes - output.count
                else {
                    throw BrowserPNGCodecError.decompressedDataTooLarge
                }
                for _ in 0..<length {
                    output.append(output[output.count - distance])
                }
            default:
                throw BrowserPNGCodecError.invalidDeflateStream
            }
        }
    }
}

private struct DeflateBitReader {
    let bytes: [UInt8]
    private(set) var byteOffset = 0
    private var bitOffset: UInt8 = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool {
        byteOffset == bytes.count && bitOffset == 0
    }

    mutating func readBits(_ count: Int) throws -> Int {
        guard count >= 0, count <= 16 else { throw BrowserPNGCodecError.invalidDeflateStream }
        var result = 0
        for bit in 0..<count {
            guard byteOffset < bytes.count else { throw BrowserPNGCodecError.invalidDeflateStream }
            let value = Int((bytes[byteOffset] >> bitOffset) & 1)
            result |= value << bit
            bitOffset += 1
            if bitOffset == 8 {
                bitOffset = 0
                byteOffset += 1
            }
        }
        return result
    }

    mutating func alignToByte() {
        guard bitOffset != 0 else { return }
        bitOffset = 0
        byteOffset += 1
    }

    mutating func readAlignedUInt16() throws -> Int {
        alignToByte()
        guard bytes.count - byteOffset >= 2 else { throw BrowserPNGCodecError.invalidDeflateStream }
        let value = Int(bytes[byteOffset]) | (Int(bytes[byteOffset + 1]) << 8)
        byteOffset += 2
        return value
    }

    mutating func readAlignedBytes(count: Int) throws -> [UInt8] {
        alignToByte()
        guard count >= 0, count <= bytes.count - byteOffset else { throw BrowserPNGCodecError.invalidDeflateStream }
        let result = Array(bytes[byteOffset..<(byteOffset + count)])
        byteOffset += count
        return result
    }
}

private struct DeflateHuffmanTree {
    private let symbolsByCode: [Int: Int]
    private let maximumCodeLength: Int

    init(lengths: [Int], allowsEmpty: Bool = false) throws {
        guard !lengths.isEmpty else { throw BrowserPNGCodecError.invalidDeflateStream }
        let nonZeroLengths = lengths.filter { $0 != 0 }
        if nonZeroLengths.isEmpty {
            guard allowsEmpty else { throw BrowserPNGCodecError.invalidDeflateStream }
            symbolsByCode = [:]
            maximumCodeLength = 0
            return
        }

        var counts = [Int](repeating: 0, count: 16)
        for length in lengths {
            guard (0...15).contains(length) else { throw BrowserPNGCodecError.invalidDeflateStream }
            if length > 0 {
                counts[length] += 1
            }
        }

        var nextCode = [Int](repeating: 0, count: 16)
        var code = 0
        for length in 1...15 {
            code = (code + counts[length - 1]) << 1
            guard code + counts[length] <= (1 << length) else { throw BrowserPNGCodecError.invalidDeflateStream }
            nextCode[length] = code
        }

        var decodedSymbols: [Int: Int] = [:]
        decodedSymbols.reserveCapacity(nonZeroLengths.count)
        for (symbol, length) in lengths.enumerated() where length > 0 {
            let canonicalCode = nextCode[length]
            nextCode[length] += 1
            let reversedCode = Self.reverseBits(canonicalCode, count: length)
            let key = (length << 16) | reversedCode
            guard decodedSymbols[key] == nil else { throw BrowserPNGCodecError.invalidDeflateStream }
            decodedSymbols[key] = symbol
        }
        symbolsByCode = decodedSymbols
        maximumCodeLength = lengths.max() ?? 0
    }

    func decode(reader: inout DeflateBitReader) throws -> Int {
        guard maximumCodeLength > 0 else { throw BrowserPNGCodecError.invalidDeflateStream }
        var code = 0
        for length in 1...maximumCodeLength {
            code |= (try reader.readBits(1)) << (length - 1)
            if let symbol = symbolsByCode[(length << 16) | code] {
                return symbol
            }
        }
        throw BrowserPNGCodecError.invalidDeflateStream
    }

    private static func reverseBits(_ value: Int, count: Int) -> Int {
        var input = value
        var result = 0
        for _ in 0..<count {
            result = (result << 1) | (input & 1)
            input >>= 1
        }
        return result
    }
}
