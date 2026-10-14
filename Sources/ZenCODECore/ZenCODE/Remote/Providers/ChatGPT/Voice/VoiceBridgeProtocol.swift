import Foundation

/// Private voice-only IPC, not ACP. Stdout is a pipe carrying data, never a log.
public struct VoiceBridgeCommand: Codable, Sendable {
    public let version: Int
    public let id: String
    public let command: String
    public let sdp: String?
    public let text: String?
    public let delegationID: String?
    public let projects: [String]?
    public static let maximumLineBytes = 131_072
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumLineBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["version", "id", "command", "sdp", "text", "delegationID", "projects"]) else { throw VoiceBridgeFailure.invalidCommand }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, validIdentifier(value.id) else { throw VoiceBridgeFailure.invalidCommand }
        switch value.command {
        case "open":
            guard let sdp = value.sdp, sdp.utf8.count <= 65_536, sdp.hasPrefix("v=0"),
                  let projects = value.projects, !projects.isEmpty,
                  projects.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }),
                  value.text == nil, value.delegationID == nil else { throw VoiceBridgeFailure.invalidCommand }
        case "speak":
            guard let text = value.text, !text.isEmpty, text.utf8.count <= 16_000,
                  value.sdp == nil, value.projects == nil, value.delegationID == nil else { throw VoiceBridgeFailure.invalidCommand }
        case "delegationResult":
            guard let text = value.text, text.utf8.count <= 16_000, let id = value.delegationID, validIdentifier(id),
                  value.sdp == nil, value.projects == nil else { throw VoiceBridgeFailure.invalidCommand }
        case "close":
            guard value.sdp == nil, value.text == nil, value.projects == nil, value.delegationID == nil else { throw VoiceBridgeFailure.invalidCommand }
        default: throw VoiceBridgeFailure.invalidCommand
        }
        return value
    }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 160 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
}
public struct VoiceBridgeEvent: Encodable, Sendable {
    public let version = 1
    public var type: String
    public var id: String?
    public var sdp: String?
    public var text: String?
    public var code: String?
    public var status: Int?
    public init(type: String, id: String? = nil, sdp: String? = nil, text: String? = nil, code: String? = nil, status: Int? = nil) {
        self.type = type; self.id = id; self.sdp = sdp; self.text = text; self.code = code; self.status = status
    }
}
public enum VoiceBridgeFailure: Error, Sendable, Equatable { case invalidCommand, authMissing, authExpired, invalidState, overflow, timeout, disconnected }

public struct VoiceBridgeFramer: Sendable {
    private var pending = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                guard !pending.isEmpty else { throw VoiceBridgeFailure.invalidCommand }
                lines.append(pending); pending = Data()
            } else {
                guard pending.count < VoiceBridgeCommand.maximumLineBytes else { throw VoiceBridgeFailure.overflow }
                pending.append(byte)
            }
        }
        return lines
    }
    public mutating func finish() throws {
        defer { pending = Data() }
        guard pending.isEmpty else { throw VoiceBridgeFailure.invalidCommand }
    }
}
