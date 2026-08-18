import Testing
@testable import ToolCore

@Suite
struct ToolSecretRedactorTests {
    @Test
    func environmentDescriptionRedactsCredentialKeysAndIsStable() {
        let rendered = ToolSecretRedactor.redactedEnvironmentDescription([
            "VISIBLE": "value",
            "API_TOKEN": "must-not-appear"
        ])
        #expect(rendered == "[API_TOKEN: [REDACTED], VISIBLE: value]")
        #expect(!rendered.contains("must-not-appear"))
    }
}
