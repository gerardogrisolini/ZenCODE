//
//  ACPCommandWire.swift
//  ZenCODE
//
//  The JSON-RPC wire double of the ACP command tests, which records what a
//  bridge writes and decodes the session updates, the plan entries, and the
//  stop reasons out of it.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// One `plan` update as the client received it.
struct ACPPlan: Equatable {
    struct Entry: Equatable {
        let content: String
        let status: String
    }

    let entries: [Entry]
}

final class ACPCommandWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    func updateTexts(kind: String) -> [String] {
        storage.withLock { values in
            values.compactMap { value in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let params = object["params"]?.objectValue,
                      let update = params["update"]?.objectValue,
                      update["sessionUpdate"] == .string(kind) else {
                    return nil
                }
                return update["content"]?.objectValue?["text"]?.stringValue
            }
        }
    }

    /// The `session/update` payloads of `kind`, in order.
    func updates(kind: String) -> [[String: JSONValue]] {
        storage.withLock { values in
            values.compactMap { value in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let update = object["params"]?.objectValue?["update"]?.objectValue,
                      update["sessionUpdate"] == .string(kind) else {
                    return nil
                }
                return update
            }
        }
    }

    /// The `title` of every `session_info_update`, in order.
    func sessionTitles() -> [String] {
        updates(kind: "session_info_update").compactMap { $0["title"]?.stringValue }
    }

    /// The `plan` updates sent, in order. An entry that lost its `content` or
    /// its `status` keeps a placeholder: a malformed plan must never read as an
    /// empty one.
    func plans() -> [ACPPlan] {
        storage.withLock { values in
            values.compactMap { value -> ACPPlan? in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let update = object["params"]?.objectValue?["update"]?.objectValue,
                      update["sessionUpdate"] == .string("plan") else {
                    return nil
                }
                let entries = (update["entries"]?.arrayValue ?? []).map { entry in
                    let fields = entry.objectValue
                    return ACPPlan.Entry(
                        content: fields?["content"]?.stringValue ?? "<missing content>",
                        status: fields?["status"]?.stringValue ?? "<missing status>"
                    )
                }
                return ACPPlan(entries: entries)
            }
        }
    }

    /// The content of every `plan` sent, one array per update.
    func planContents() -> [[String]] {
        plans().map { $0.entries.map(\.content) }
    }

    /// The status of every `plan` sent, one array per update.
    func planStatuses() -> [[String]] {
        plans().map { $0.entries.map(\.status) }
    }

    /// What reached the client, in order: the update kind of each
    /// `session/update`, and `result:<id>` for a reply.
    func timeline() -> [String] {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue else { return nil }
                if let update = object["params"]?.objectValue?["update"]?.objectValue,
                   let kind = update["sessionUpdate"]?.stringValue {
                    return kind
                }
                guard object["result"] != nil,
                      let id = object["id"]?.numberValue else {
                    return nil
                }
                return "result:\(Int(id))"
            }
        }
    }

    func stopReason(for id: Int) -> String? {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue,
                      object["id"] == .number(Double(id)) else {
                    return nil
                }
                return object["result"]?.objectValue?["stopReason"]?.stringValue
            }.first
        }
    }
}
