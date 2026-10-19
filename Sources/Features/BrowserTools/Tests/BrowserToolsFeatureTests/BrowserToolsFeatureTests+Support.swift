import Foundation
import Synchronization
@testable import BrowserToolsFeature

func browserTemporaryRoot(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

func browserCDPEvent(_ method: String, _ params: [String: Any]) -> CDPEvent {
    CDPEvent(method: method, paramsData: try! JSONSerialization.data(withJSONObject: params), sessionID: nil)
}

final class EventRecorder: Sendable {
    private let storage = Mutex<[CDPEvent]>([])

    func append(_ event: CDPEvent) {
        storage.withLock { $0.append(event) }
    }

    var events: [CDPEvent] {
        storage.withLock { $0 }
    }
}

func browserPNGHeader(width: UInt32, height: UInt32, suffix: [UInt8]) -> Data {
    var bytes: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
    bytes += [0, 0, 0, 13]
    bytes += [73, 72, 68, 82]
    for value in [width, height] {
        bytes += [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ]
    }
    bytes += suffix
    return Data(bytes)
}

func schemaObject(_ schema: String) throws -> [String: Any] {
    let object = try JSONSerialization.jsonObject(with: Data(schema.utf8))
    guard let dictionary = object as? [String: Any] else {
        throw NSError(
            domain: "BrowserToolsFeatureTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Feature schema is not a JSON object"]
        )
    }
    return dictionary
}

/// Complete, independently precomputed PNG fixtures. Their IDAT chunks use
/// normal zlib compression rather than the BrowserPNGCodec encoder so decoder
/// coverage does not depend on round-tripping through the implementation.
func browserVisualDiffBaselinePNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAI0lEQVR4nGPgEpH7r2Fk898tIOo/Q0pexf+mnmn/F6za8h8AhFkMqbs7RigAAAAASUVORK5CYII=")!
}

func browserVisualDiffCandidatePNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAIklEQVR4nGPgEpH7z8jE/N8tIOo/Q0pexf+mnmn/OTnYGwBzEAm0JbLgngAAAABJRU5ErkJggg==")!
}

func browserVisualDiffSmallPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgZGL+DwABFAEG1rmmRQAAAABJRU5ErkJggg==")!
}

func browserVisualDiffFilteredPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAMAAAAFCAYAAACAcVaiAAAAOElEQVR4nGNgZGL+r8Zr8d9bIvc/o4gu1ztVblMGEGYS1mZ/D8PM6uECcTLScj9AmAUsys3OAMIAD0IO7Hch3toAAAAASUVORK5CYII=")!
}

func browserVisualDiffRGBPNG() -> Data {
    Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGPgUbLwi6oGAAPyAYrtNuu8AAAAAElFTkSuQmCC")!
}

struct StaticBrowserHostResolver: BrowserHostResolving {
    let addressesByHost: [String: [String]]

    func resolve(host: String) throws -> [String] {
        guard let addresses = addressesByHost[host] else {
            throw BrowserNetworkGuardError.unresolvedHost(host)
        }
        return addresses
    }
}
