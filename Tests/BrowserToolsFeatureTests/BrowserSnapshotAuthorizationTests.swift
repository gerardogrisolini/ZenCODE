import Foundation
@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserSnapshotAuthorizationTests {
    @Test
    func hostStoreIsPageScopedAtomicPersistentAndDocumentBound() throws {
        let root = temporarySnapshotStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("snapshot-authorizations.json")
        let firstStore = BrowserSnapshotStateStore(
            stateURL: stateURL,
            maximumPageCount: 2,
            maximumRefsPerSnapshot: 2
        )
        let firstDocument = BrowserDocumentIdentity(frameID: "frame-a", loaderID: "loader-a")
        let secondDocument = BrowserDocumentIdentity(frameID: "frame-a", loaderID: "loader-b")

        let firstRecorded = try firstStore.record(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            allowedRefs: ["ax-1", "ax-2"],
            document: firstDocument
        )
        #expect(firstRecorded)

        // A newly-created store represents a later one-shot feature process;
        // it must see the Browser-owned record written by the snapshot process.
        let secondStore = BrowserSnapshotStateStore(
            stateURL: stateURL,
            maximumPageCount: 2,
            maximumRefsPerSnapshot: 2
        )
        let firstAuthorized = try secondStore.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            ref: "ax-1",
            document: firstDocument
        )
        #expect(firstAuthorized)

        // Recording the next snapshot atomically replaces (and revokes) the
        // previous one for this page.
        let secondRecorded = try secondStore.record(
            pageID: "page-a",
            snapshotID: "snapshot-b",
            allowedRefs: ["ax-3"],
            document: firstDocument
        )
        #expect(secondRecorded)
        let oldSnapshotAuthorized = try firstStore.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            ref: "ax-1",
            document: firstDocument
        )
        let newSnapshotAuthorized = try firstStore.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-b",
            ref: "ax-3",
            document: firstDocument
        )
        #expect(!oldSnapshotAuthorized)
        #expect(newSnapshotAuthorized)

        // A main-frame loader change fails closed and purges that page record.
        let changedDocumentAuthorized = try secondStore.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-b",
            ref: "ax-3",
            document: secondDocument
        )
        let restoredOldDocumentAuthorized = try firstStore.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-b",
            ref: "ax-3",
            document: firstDocument
        )
        #expect(!changedDocumentAuthorized)
        #expect(!restoredOldDocumentAuthorized)
    }

    @Test
    func hostStoreRejectsOversizedStateAndEvictsByPageBound() throws {
        let root = temporarySnapshotStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSnapshotStateStore(
            stateURL: root.appendingPathComponent("snapshot-authorizations.json"),
            maximumPageCount: 1,
            maximumRefsPerSnapshot: 1
        )
        let document = BrowserDocumentIdentity(frameID: "frame", loaderID: "loader")

        let oversized = try store.record(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            allowedRefs: ["ax-1", "ax-2"],
            document: document
        )
        #expect(!oversized)

        let first = try store.record(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            allowedRefs: ["ax-1"],
            document: document
        )
        let second = try store.record(
            pageID: "page-b",
            snapshotID: "snapshot-b",
            allowedRefs: ["ax-2"],
            document: document
        )
        #expect(first)
        #expect(second)
        let firstPageAuthorized = try store.isAuthorized(
            pageID: "page-a",
            snapshotID: "snapshot-a",
            ref: "ax-1",
            document: document
        )
        let secondPageAuthorized = try store.isAuthorized(
            pageID: "page-b",
            snapshotID: "snapshot-b",
            ref: "ax-2",
            document: document
        )
        let count = try store.recordCount()
        #expect(!firstPageAuthorized)
        #expect(secondPageAuthorized)
        #expect(count == 1)
    }

    @Test
    func concurrentWritesRetainEveryBoundedPageRecordAtomically() async throws {
        let root = temporarySnapshotStateDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserSnapshotStateStore(
            stateURL: root.appendingPathComponent("snapshot-authorizations.json"),
            maximumPageCount: 32,
            maximumRefsPerSnapshot: 2
        )
        let document = BrowserDocumentIdentity(frameID: "frame", loaderID: "loader")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    guard try store.record(
                        pageID: "page-\(index)",
                        snapshotID: "snapshot-\(index)",
                        allowedRefs: ["ax-\(index)"],
                        document: document
                    ) else {
                        throw CancellationError()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(try store.recordCount() == 20)
        for index in 0..<20 {
            let authorized = try store.isAuthorized(
                pageID: "page-\(index)",
                snapshotID: "snapshot-\(index)",
                ref: "ax-\(index)",
                document: document
            )
            #expect(authorized)
        }
    }

    @Test
    func mainFrameIdentityRequiresFrameAndLoader() throws {
        let identity = try BrowserDocumentIdentity.parse([
            "result": [
                "frameTree": [
                    "frame": [
                        "id": "frame-main",
                        "loaderId": "loader-main",
                    ],
                ],
            ],
        ])
        #expect(identity == BrowserDocumentIdentity(frameID: "frame-main", loaderID: "loader-main"))

        #expect(throws: CDPError.self) {
            try BrowserDocumentIdentity.parse([
                "result": ["frameTree": ["frame": ["id": "frame-main"]]],
            ])
        }
    }

    @Test
    func accessibilitySnapshotRefCountMatchesAuthorizationBound() throws {
        let rawNodes: [[String: Any]] = (0...BrowserAccessibilitySnapshot.maximumSnapshotRefCount).map { index in
            [
                "nodeId": "node-\(index)",
                "backendDOMNodeId": index + 1,
                "ignored": false,
                "role": ["value": "button"],
            ]
        }
        let snapshot = try BrowserAccessibilitySnapshot.parse(
            ["result": ["nodes": rawNodes]],
            interactiveOnly: false
        )

        // The encoded output budget may cut off before the ref-count budget;
        // in either case only emitted refs are retained as resolver targets.
        #expect(snapshot.nodes.count <= BrowserSnapshotAuthorizationLimits.maximumRefsPerSnapshot)
        #expect(snapshot.targets.count == snapshot.nodes.count)
        #expect(snapshot.truncated)
    }

    private func temporarySnapshotStateDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserSnapshotAuthorizationTests-\(UUID().uuidString)", isDirectory: true)
    }
}
