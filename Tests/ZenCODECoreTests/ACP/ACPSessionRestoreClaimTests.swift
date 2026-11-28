//
//  ACPSessionRestoreClaimTests.swift
//  ZenCODE
//
//  The id a `session/load` or `session/resume` opens is claimed before it
//  suspends: two restores of the same id never open two incarnations, and the
//  one that loses leaves no host slot, MCP server, or task-graph observer
//  behind. A close or a delete of the id fences the restore that is opening it.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing
import ToolCore

@Suite(.timeLimit(.minutes(1)))
struct ACPSessionRestoreClaimTests {
    private final class Transport: Sendable {
        private let messages = Mutex<[JSONValue]>([])

        var sink: ACPWriter.Sink {
            { [self] data in
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    messages.withLock { $0.append(value) }
                }
            }
        }

        func result(id: Int) -> [String: JSONValue]? {
            response(id: id)?["result"]?.objectValue
        }

        func error(id: Int) -> [String: JSONValue]? {
            response(id: id)?["error"]?.objectValue
        }

        private func response(id: Int) -> [String: JSONValue]? {
            messages.withLock { values in
                values.first { value in
                    let object = value.objectValue
                    return object?["id"] == .number(Double(id)) && object?["method"] == nil
                }?.objectValue
            }
        }
    }

    private static func makeBridge() throws -> (ZenCODEACPBridge, Transport) {
        let transport = Transport()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                )
            ],
            runMode: .acp,
            workingDirectory: FileManager.default.temporaryDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: transport.sink),
            backendFactory: { _, _ in CapturingACPBackend() }
        )
        return (bridge, transport)
    }

    private static func request(
        _ id: Int,
        _ method: String,
        sessionID: String
    ) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": ["sessionId": sessionID] as [String: Any],
        ]
    }

    @Test
    func aSecondLoadOfAnIdAnotherLoadIsOpeningIsRefused() async throws {
        let (bridge, transport) = try Self.makeBridge()
        let operation = try await bridge.registerLifecycleOperationForTesting()
        #expect(await bridge.reserveSessionRestore("shared-id", operation: operation))

        await bridge.handleMessage(Self.request(1, "session/load", sessionID: "shared-id"))

        // The second request is answered at once, before it opens anything.
        let error = try #require(transport.error(id: 1))
        #expect(error["code"]?.numberValue.map { Int($0) } == -32602)
        #expect(
            error["message"]?.acpStringValue
                == ZenCODEACPBridge.sessionRestoreBusyMessage("shared-id")
        )
        // The loser leaves no incarnation behind, and the claim stands.
        #expect(await bridge.testSessionCount() == 0)
        #expect(await bridge.isSessionRestoreClaimed("shared-id"))

        // The restore that held it releases it, and the next load runs.
        await bridge.releaseSessionRestore("shared-id", operation: operation)
        #expect(await bridge.isSessionRestoreClaimed("shared-id") == false)
        await bridge.handleMessage(Self.request(2, "session/load", sessionID: "shared-id"))
        #expect(transport.error(id: 2) == nil)
        #expect(transport.result(id: 2)?["sessionId"] == nil)
        #expect(await bridge.isSessionRestoreClaimed("shared-id") == false)
        await bridge.shutdown()
    }

    @Test(arguments: ["session/close", "session/delete"])
    func closingOrDeletingTheIdFencesTheRestoreThatIsOpeningIt(method: String) async throws {
        let (bridge, transport) = try Self.makeBridge()
        let operation = try await bridge.registerLifecycleOperationForTesting()
        #expect(await bridge.reserveSessionRestore("fenced-id", operation: operation))

        await bridge.handleMessage(Self.request(3, method, sessionID: "fenced-id"))

        // The restore's next re-check fails: it answers the error of a closed
        // session and releases the host slot and the MCP servers it opened.
        #expect(await bridge.isLifecycleOperationLive(operation) == false)
        // It keeps the id claimed until it unwinds, so no second restore of the
        // deleted session starts meanwhile.
        #expect(await bridge.isSessionRestoreClaimed("fenced-id"))
        await bridge.releaseSessionRestore("fenced-id", operation: operation)
        #expect(await bridge.isSessionRestoreClaimed("fenced-id") == false)
        #expect(transport.error(id: 3) == nil)
        await bridge.shutdown()
    }

    @Test
    func shutdownReleasesTheClaimsOfRunningRestores() async throws {
        let (bridge, _) = try Self.makeBridge()
        let operation = try await bridge.registerLifecycleOperationForTesting()
        #expect(await bridge.reserveSessionRestore("closing-id", operation: operation))

        await bridge.shutdown()

        #expect(await bridge.isSessionRestoreClaimed("closing-id") == false)
    }
}
