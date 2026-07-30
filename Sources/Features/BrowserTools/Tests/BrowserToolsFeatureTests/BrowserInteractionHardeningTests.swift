@testable import BrowserToolsFeature
import Testing

@Suite
struct BrowserInteractionHardeningTests {
    @Test
    func selectFunctionRejectsDisabledOptionAndDisabledOptgroup() {
        // The action source is fixed Browser-owned code; inspect it here so a
        // future refactor cannot silently remove either native disabled guard.
        let function = CDPSession.selectOptionFunction
        #expect(function.contains("option.disabled"))
        #expect(function.contains("HTMLOptGroupElement"))
        #expect(function.contains("option.parentElement.disabled"))
        #expect(function.contains("return 'disabled'"))
    }
}
