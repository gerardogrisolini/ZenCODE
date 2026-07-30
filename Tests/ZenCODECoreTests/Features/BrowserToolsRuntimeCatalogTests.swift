import Testing
@testable import ZenCODECore

@Suite
struct BrowserToolsRuntimeCatalogTests {
    @Test
    func bundledRuntimeCatalogDelegatesDescriptorOwnershipToBrowserFeature() throws {
        let feature = try #require(
            SwiftFeatureRuntime.bundledFeatureDefinitions()
                .first(where: { $0.id == "browser-tools" })
        )
        #expect(feature.tools.isEmpty)
        #expect(feature.toolNamePrefixes == ["browser."])
        #expect(feature.discoversToolsAtRuntime)
    }
}
