import Foundation
import Testing
@testable import ZenCODECore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct SubscriptionCatalogPaginationValidationTests {
    // Every invalid completion marker is exercised on both the first and second page.
    @Test(arguments: ["", ",\"has_more\":\"false\"", ",\"has_more\":null", ",\"has_more\":0", ",\"has_more\":1",
                      ",\"has_more\":true", ",\"has_more\":true,\"last_id\":\"\"", ",\"has_more\":true,\"last_id\":42"],
          [false, true])
    func malformedPagePreservesPreviousCache(marker: String, secondPage: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lineage = UUID()
        let success = SubscriptionModelCatalogClient(directory: directory) { request in
            (Data("{\"data\":[{\"id\":\"previous-complete-catalog\"}],\"has_more\":false}".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        _ = try await success.load(provider: .anthropic, accessToken: "fixture", catalogScopeID: lineage)
        let cacheURL = success.cacheURL(provider: .anthropic, scope: lineage.uuidString.lowercased())
        let original = try Data(contentsOf: cacheURL)
        let malformed = SubscriptionModelCatalogClient(directory: directory) { request in
            let json: String
            if secondPage && request.url?.query == nil {
                json = "{\"data\":[{\"id\":\"partial-first\"}],\"has_more\":true,\"last_id\":\"partial-first\"}"
            } else {
                json = "{\"data\":[{\"id\":\"partial-last\"}]\(marker)}"
            }
            return (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await #expect(throws: SubscriptionModelCatalogClient.CatalogError.self) {
            try await malformed.fetch(provider: .anthropic, accessToken: "fixture", accountID: nil)
        }
        let result = try await malformed.load(provider: .anthropic, accessToken: "fixture", catalogScopeID: lineage)
        #expect(result.isCached)
        #expect(result.models.map(\.id) == ["previous-complete-catalog"])
        #expect(try Data(contentsOf: cacheURL) == original)
    }
}
