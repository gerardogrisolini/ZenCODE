import Testing
import FeatureKit
import LocalToolsSupport

@Suite
struct LocalFeatureToolsRegistryContractTests {
    @Test
    func publicToolGroupsExposeTheExpectedTools() {
        #expect(LocalFeatureTools.fileTools().map(\.descriptor.name) == [
            "local.pwd", "local.ls", "local.readFile", "local.readFiles",
            "local.inspectFile", "local.writeFile", "local.replace", "local.editFile",
            "local.multiEdit", "local.append", "local.mkdir", "local.delete",
            "local.move", "local.applyPatch"
        ])
        #expect(LocalFeatureTools.searchTools().map(\.descriptor.name) == [
            "search.glob", "search.grep", "search.locate"
        ])
        #expect(LocalFeatureTools.textTools().map(\.descriptor.name) == [
            "text.head", "text.tail", "text.sort", "text.wc"
        ])
    }
}
