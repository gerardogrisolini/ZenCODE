//
//  BrowserPNGCodec.swift
//  BrowserToolsFeature
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Bounded, pure-Swift PNG decoding and encoding for Browser visual diffs.
//  The implementation deliberately supports the PNG shape emitted by browser
//  screenshots (8-bit RGB/RGBA, non-interlaced) and rejects every other shape.
//

import Foundation

enum BrowserPNGCodecError: LocalizedError, Sendable {
    case invalidPNGSignature
    case malformedPNGChunk
    case invalidPNGChunkCRC
    case missingPNGHeader
    case invalidPNGHeader
    case unsupportedPNGFormat
    case missingPNGImageData
    case missingPNGEnd
    case trailingPNGData
    case imageTooLarge
    case compressedDataTooLarge
    case invalidZlibStream
    case invalidDeflateStream
    case decompressedDataTooLarge
    case unexpectedDecompressedSize
    case invalidPNGFilter(UInt8)
    case invalidImageBuffer
    case encodedOutputTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidPNGSignature:
            "Browser visual comparison requires a valid PNG signature."
        case .malformedPNGChunk:
            "Browser visual comparison rejected a malformed PNG chunk."
        case .invalidPNGChunkCRC:
            "Browser visual comparison rejected a PNG chunk with an invalid CRC."
        case .missingPNGHeader:
            "Browser visual comparison requires a PNG IHDR chunk."
        case .invalidPNGHeader:
            "Browser visual comparison rejected invalid PNG dimensions or header fields."
        case .unsupportedPNGFormat:
            "Browser visual comparison supports only non-interlaced 8-bit RGB or RGBA PNGs."
        case .missingPNGImageData:
            "Browser visual comparison requires PNG image data."
        case .missingPNGEnd:
            "Browser visual comparison requires a terminating PNG IEND chunk."
        case .trailingPNGData:
            "Browser visual comparison rejected trailing PNG data."
        case .imageTooLarge:
            "Browser visual comparison rejected an image beyond its decoded pixel limit."
        case .compressedDataTooLarge:
            "Browser visual comparison rejected compressed image data beyond its byte limit."
        case .invalidZlibStream:
            "Browser visual comparison rejected an invalid PNG zlib stream."
        case .invalidDeflateStream:
            "Browser visual comparison rejected an invalid PNG DEFLATE stream."
        case .decompressedDataTooLarge:
            "Browser visual comparison rejected image data beyond its decompression limit."
        case .unexpectedDecompressedSize:
            "Browser visual comparison rejected PNG image data with an unexpected size."
        case let .invalidPNGFilter(filter):
            "Browser visual comparison rejected unsupported PNG filter \(filter)."
        case .invalidImageBuffer:
            "Browser visual comparison received an invalid RGBA image buffer."
        case .encodedOutputTooLarge:
            "Browser visual comparison could not create a bounded PNG diff artifact."
        }
    }
}

/// A small, deliberately constrained PNG codec. It is independent of Apple
/// frameworks and native image utilities so the Browser feature behaves the
/// same on macOS, Linux, and WSL.
enum BrowserPNGCodec {
    struct Image: Hashable, Sendable {
        let width: Int
        let height: Int
        /// One unpremultiplied RGBA sample per pixel, in row-major order.
        let rgba: [UInt8]
    }

    /// The encoded source limit matches the Browser artifact-read limit. The
    /// decoded limits prevent a small compressed PNG from allocating an
    /// unbounded image or diff artifact.
    static let maximumEncodedBytes = 20 * 1024 * 1024
    static let maximumChunkBytes = maximumEncodedBytes
    static let maximumPixelWidth = 8_192
    static let maximumPixelHeight = 8_192
    static let maximumPixelCount = 4_000_000
    static let maximumDecodedScanlineBytes = 17 * 1024 * 1024
    static let maximumDeflateBlocks = 4_096
    private static let maximumIDATChunkBytes = 65_536

    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    private static let ihdr: [UInt8] = [73, 72, 68, 82]
    private static let idat: [UInt8] = [73, 68, 65, 84]
    private static let iend: [UInt8] = [73, 69, 78, 68]
    private static let plte: [UInt8] = [80, 76, 84, 69]
    private static let transparency: [UInt8] = [116, 82, 78, 83]

    static func decode(_ data: Data) throws -> Image {
        guard data.count <= maximumEncodedBytes else {
            throw BrowserPNGCodecError.compressedDataTooLarge
        }
        let bytes = Array(data)
        guard bytes.count >= signature.count,
              Array(bytes.prefix(signature.count)) == signature
        else {
            throw BrowserPNGCodecError.invalidPNGSignature
        }

        var cursor = signature.count
        var sawHeader = false
        var sawImageData = false
        var endedImageData = false
        var sawEnd = false
        var width: Int?
        var height: Int?
        var colorType: UInt8?
        var compressed = [UInt8]()
        compressed.reserveCapacity(min(bytes.count, maximumEncodedBytes))

        chunkLoop: while cursor < bytes.count {
            try Task.checkCancellation()
            guard bytes.count - cursor >= 12 else {
                throw BrowserPNGCodecError.malformedPNGChunk
            }
            let chunkLength = Int(readUInt32(bytes, at: cursor))
            guard chunkLength <= maximumChunkBytes else {
                throw BrowserPNGCodecError.compressedDataTooLarge
            }
            let typeStart = cursor + 4
            let payloadStart = typeStart + 4
            guard chunkLength <= bytes.count - payloadStart - 4 else {
                throw BrowserPNGCodecError.malformedPNGChunk
            }
            let payloadEnd = payloadStart + chunkLength
            let crcOffset = payloadEnd
            let type = Array(bytes[typeStart..<payloadStart])
            guard type.allSatisfy(isPNGChunkTypeByte) else {
                throw BrowserPNGCodecError.malformedPNGChunk
            }
            let expectedCRC = readUInt32(bytes, at: crcOffset)
            guard crc32(bytes, range: typeStart..<payloadEnd) == expectedCRC else {
                throw BrowserPNGCodecError.invalidPNGChunkCRC
            }
            cursor = crcOffset + 4

            if type == ihdr {
                guard !sawHeader, !sawImageData, payloadStart == signature.count + 8,
                      chunkLength == 13
                else {
                    throw BrowserPNGCodecError.invalidPNGHeader
                }
                let decodedWidth = Int(readUInt32(bytes, at: payloadStart))
                let decodedHeight = Int(readUInt32(bytes, at: payloadStart + 4))
                let bitDepth = bytes[payloadStart + 8]
                let decodedColorType = bytes[payloadStart + 9]
                let compressionMethod = bytes[payloadStart + 10]
                let filterMethod = bytes[payloadStart + 11]
                let interlaceMethod = bytes[payloadStart + 12]
                guard decodedWidth > 0, decodedHeight > 0,
                      decodedWidth <= maximumPixelWidth,
                      decodedHeight <= maximumPixelHeight
                else {
                    throw BrowserPNGCodecError.invalidPNGHeader
                }
                guard bitDepth == 8,
                      decodedColorType == 2 || decodedColorType == 6,
                      compressionMethod == 0,
                      filterMethod == 0,
                      interlaceMethod == 0
                else {
                    throw BrowserPNGCodecError.unsupportedPNGFormat
                }
                width = decodedWidth
                height = decodedHeight
                colorType = decodedColorType
                sawHeader = true
                continue
            }

            guard sawHeader else {
                throw BrowserPNGCodecError.missingPNGHeader
            }

            if type == idat {
                guard !endedImageData else {
                    throw BrowserPNGCodecError.malformedPNGChunk
                }
                sawImageData = true
                compressed.append(contentsOf: bytes[payloadStart..<payloadEnd])
                continue
            }

            if sawImageData {
                endedImageData = true
            }

            if type == iend {
                guard chunkLength == 0, sawImageData else {
                    throw BrowserPNGCodecError.missingPNGImageData
                }
                sawEnd = true
                break chunkLoop
            }

            if type == plte {
                guard !sawImageData, chunkLength > 0, chunkLength <= 768, chunkLength.isMultiple(of: 3) else {
                    throw BrowserPNGCodecError.malformedPNGChunk
                }
                continue
            }

            // tRNS changes RGB alpha semantics. Ignoring it would compare a
            // different image, so reject it rather than silently miscompare.
            if type == transparency {
                throw BrowserPNGCodecError.unsupportedPNGFormat
            }

            // PNG critical chunk names begin with an uppercase ASCII letter.
            // Unknown critical data could affect pixel interpretation.
            if type[0] & 0x20 == 0 {
                throw BrowserPNGCodecError.unsupportedPNGFormat
            }
        }

        guard sawHeader else { throw BrowserPNGCodecError.missingPNGHeader }
        guard sawEnd else { throw BrowserPNGCodecError.missingPNGEnd }
        guard cursor == bytes.count else { throw BrowserPNGCodecError.trailingPNGData }
        guard let width, let height, let colorType else {
            throw BrowserPNGCodecError.invalidPNGHeader
        }
        guard !compressed.isEmpty else {
            throw BrowserPNGCodecError.missingPNGImageData
        }

        let channels = colorType == 2 ? 3 : 4
        let pixelCount = try checkedProduct(width, height)
        guard pixelCount <= maximumPixelCount else {
            throw BrowserPNGCodecError.imageTooLarge
        }
        let rowBytes = try checkedProduct(width, channels)
        let scanlineBytes = try checkedProduct(height, rowBytes + 1)
        guard scanlineBytes <= maximumDecodedScanlineBytes else {
            throw BrowserPNGCodecError.imageTooLarge
        }
        let rgbaBytes = try checkedProduct(pixelCount, 4)
        guard rgbaBytes <= maximumPixelCount * 4 else {
            throw BrowserPNGCodecError.imageTooLarge
        }

        let inflated = try inflateZlib(compressed, maximumOutputBytes: scanlineBytes)
        guard inflated.count == scanlineBytes else {
            throw BrowserPNGCodecError.unexpectedDecompressedSize
        }
        return try unfilter(
            scanlines: inflated,
            width: width,
            height: height,
            channels: channels,
            rgbaByteCount: rgbaBytes
        )
    }

    /// Encodes an RGBA image as a PNG using bounded DEFLATE stored blocks. The
    /// encoder does not invoke a platform image framework or external process.
    static func encodeRGBA(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        guard width > 0, height > 0,
              width <= maximumPixelWidth,
              height <= maximumPixelHeight
        else {
            throw BrowserPNGCodecError.invalidPNGHeader
        }
        let pixelCount = try checkedProduct(width, height)
        guard pixelCount <= maximumPixelCount else {
            throw BrowserPNGCodecError.imageTooLarge
        }
        let expectedRGBABytes = try checkedProduct(pixelCount, 4)
        guard rgba.count == expectedRGBABytes else {
            throw BrowserPNGCodecError.invalidImageBuffer
        }
        let rowBytes = try checkedProduct(width, 4)
        let scanlineBytes = try checkedProduct(height, rowBytes + 1)
        guard scanlineBytes <= maximumDecodedScanlineBytes else {
            throw BrowserPNGCodecError.imageTooLarge
        }

        var scanlines = [UInt8]()
        scanlines.reserveCapacity(scanlineBytes)
        for row in 0..<height {
            try Task.checkCancellation()
            scanlines.append(0) // PNG filter: None
            let start = row * rowBytes
            scanlines.append(contentsOf: rgba[start..<(start + rowBytes)])
        }

        let compressed = try zlibStoreCompressed(scanlines)
        var png = signature
        var header = [UInt8]()
        header.reserveCapacity(13)
        appendUInt32(UInt32(width), to: &header)
        appendUInt32(UInt32(height), to: &header)
        header += [8, 6, 0, 0, 0] // 8-bit RGBA, zlib, adaptive filters, no interlace
        appendChunk(type: ihdr, payload: header, to: &png)

        var offset = 0
        while offset < compressed.count {
            let count = min(maximumIDATChunkBytes, compressed.count - offset)
            appendChunk(type: idat, payload: Array(compressed[offset..<(offset + count)]), to: &png)
            offset += count
        }
        appendChunk(type: iend, payload: [], to: &png)
        guard png.count <= maximumEncodedBytes else {
            throw BrowserPNGCodecError.encodedOutputTooLarge
        }
        return Data(png)
    }

    private static func unfilter(
        scanlines: [UInt8],
        width: Int,
        height: Int,
        channels: Int,
        rgbaByteCount: Int
    ) throws -> Image {
        let rowBytes = try checkedProduct(width, channels)
        var prior = [UInt8](repeating: 0, count: rowBytes)
        var current = [UInt8](repeating: 0, count: rowBytes)
        var rgba = [UInt8](repeating: 0, count: rgbaByteCount)
        var sourceOffset = 0

        for row in 0..<height {
            try Task.checkCancellation()
            let filter = scanlines[sourceOffset]
            sourceOffset += 1
            guard filter <= 4 else {
                throw BrowserPNGCodecError.invalidPNGFilter(filter)
            }
            for columnByte in 0..<rowBytes {
                let encoded = scanlines[sourceOffset + columnByte]
                let left = columnByte >= channels ? current[columnByte - channels] : 0
                let above = prior[columnByte]
                let upperLeft = columnByte >= channels ? prior[columnByte - channels] : 0
                switch filter {
                case 0:
                    current[columnByte] = encoded
                case 1:
                    current[columnByte] = encoded &+ left
                case 2:
                    current[columnByte] = encoded &+ above
                case 3:
                    current[columnByte] = encoded &+ UInt8((Int(left) + Int(above)) / 2)
                case 4:
                    current[columnByte] = encoded &+ paeth(left, above, upperLeft)
                default:
                    throw BrowserPNGCodecError.invalidPNGFilter(filter)
                }
            }
            sourceOffset += rowBytes

            let rgbaRowStart = row * width * 4
            if channels == 4 {
                for pixel in 0..<width {
                    let source = pixel * 4
                    let destination = rgbaRowStart + source
                    rgba[destination] = current[source]
                    rgba[destination + 1] = current[source + 1]
                    rgba[destination + 2] = current[source + 2]
                    rgba[destination + 3] = current[source + 3]
                }
            } else {
                for pixel in 0..<width {
                    let source = pixel * 3
                    let destination = rgbaRowStart + pixel * 4
                    rgba[destination] = current[source]
                    rgba[destination + 1] = current[source + 1]
                    rgba[destination + 2] = current[source + 2]
                    rgba[destination + 3] = 255
                }
            }
            swap(&prior, &current)
        }
        return Image(width: width, height: height, rgba: rgba)
    }

    private static func paeth(_ left: UInt8, _ above: UInt8, _ upperLeft: UInt8) -> UInt8 {
        let predictor = Int(left) + Int(above) - Int(upperLeft)
        let leftDistance = abs(predictor - Int(left))
        let aboveDistance = abs(predictor - Int(above))
        let upperLeftDistance = abs(predictor - Int(upperLeft))
        if leftDistance <= aboveDistance, leftDistance <= upperLeftDistance {
            return left
        }
        if aboveDistance <= upperLeftDistance {
            return above
        }
        return upperLeft
    }

    private static func zlibStoreCompressed(_ bytes: [UInt8]) throws -> [UInt8] {
        guard !bytes.isEmpty else {
            throw BrowserPNGCodecError.invalidImageBuffer
        }
        var output = [UInt8](arrayLiteral: 0x78, 0x01)
        output.reserveCapacity(bytes.count + (bytes.count / 65_535 + 1) * 5 + 6)
        var offset = 0
        while offset < bytes.count {
            try Task.checkCancellation()
            let count = min(65_535, bytes.count - offset)
            let isFinal = offset + count == bytes.count
            output.append(isFinal ? 0x01 : 0x00)
            let length = UInt16(count)
            let complement = ~length
            output.append(UInt8(length & 0x00FF))
            output.append(UInt8(length >> 8))
            output.append(UInt8(complement & 0x00FF))
            output.append(UInt8(complement >> 8))
            output.append(contentsOf: bytes[offset..<(offset + count)])
            offset += count
        }
        appendUInt32(adler32(bytes), to: &output)
        guard output.count <= maximumEncodedBytes else {
            throw BrowserPNGCodecError.encodedOutputTooLarge
        }
        return output
    }

    private static func appendChunk(type: [UInt8], payload: [UInt8], to output: inout [UInt8]) {
        appendUInt32(UInt32(payload.count), to: &output)
        let crcStart = output.count
        output.append(contentsOf: type)
        output.append(contentsOf: payload)
        appendUInt32(crc32(output, range: crcStart..<output.count), to: &output)
    }

    private static func appendUInt32(_ value: UInt32, to output: inout [UInt8]) {
        output.append(UInt8((value >> 24) & 0xFF))
        output.append(UInt8((value >> 16) & 0xFF))
        output.append(UInt8((value >> 8) & 0xFF))
        output.append(UInt8(value & 0xFF))
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
    }

    private static func checkedProduct(_ left: Int, _ right: Int) throws -> Int {
        let result = left.multipliedReportingOverflow(by: right)
        guard !result.overflow else {
            throw BrowserPNGCodecError.imageTooLarge
        }
        return result.partialValue
    }

    private static func isPNGChunkTypeByte(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        let modulus: UInt32 = 65_521
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in bytes {
            a += UInt32(byte)
            if a >= modulus { a %= modulus }
            b += a
            if b >= modulus { b %= modulus }
        }
        return (b << 16) | a
    }

    private static let crc32Table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            if crc & 1 == 1 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
        return crc
    }

    private static func crc32(_ bytes: [UInt8], range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for index in range {
            let tableIndex = Int((crc ^ UInt32(bytes[index])) & 0xFF)
            crc = crc32Table[tableIndex] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
