import FeatureKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import ToolCore
@testable import figma_tools_feature

private func json(_ text: String) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

@Suite
struct FigmaReferenceTests {
    @Test
    func designLinkWithNodeIDResolvesToAPINodeID() throws {
        let reference = try FigmaReference.resolve(
            url: "https://www.figma.com/design/AbC123xyz/My-File?node-id=12-34&t=abc-0",
            fileKey: nil,
            nodeID: nil
        )
        #expect(reference == FigmaReference(fileKey: "AbC123xyz", nodeID: "12:34"))
        #expect(reference.webURL == "https://www.figma.com/design/AbC123xyz?node-id=12-34")
    }

    @Test
    func branchLinksResolveToTheBranchKey() throws {
        let parsed = try FigmaReference.parse(link: "https://www.figma.com/design/MAINkey/branch/BRANCHkey/File?node-id=1-2")
        #expect(parsed.fileKey == "BRANCHkey")
        #expect(parsed.nodeID == "1:2")
    }

    @Test
    func linksWithoutSchemeAndLegacyFilePathsAreAccepted() throws {
        let parsed = try FigmaReference.parse(link: "figma.com/file/KEY42/Name")
        #expect(parsed.fileKey == "KEY42")
        #expect(parsed.nodeID == nil)
    }

    @Test
    func explicitArgumentsOverrideTheLink() throws {
        let reference = try FigmaReference.resolve(
            url: "https://www.figma.com/design/LINKKEY/File?node-id=1-2",
            fileKey: nil,
            nodeID: "5:6"
        )
        #expect(reference == FigmaReference(fileKey: "LINKKEY", nodeID: "5:6"))

        let fromFileKeyLink = try FigmaReference.resolve(
            url: nil,
            fileKey: "https://www.figma.com/design/OTHER/File?node-id=7-8",
            nodeID: nil
        )
        #expect(fromFileKeyLink == FigmaReference(fileKey: "OTHER", nodeID: "7:8"))
    }

    @Test
    func instanceNodeIDsAreNormalized() throws {
        #expect(try FigmaReference.normalizeNodeID("I1-2;3-4") == "I1:2;3:4")
        #expect(try FigmaReference.normalizeNodeID("1%3A2") == "1:2")
    }

    @Test
    func invalidReferencesAreRejected() {
        #expect(throws: FigmaToolsError.self) {
            try FigmaReference.parse(link: "https://example.com/design/KEY/File")
        }
        #expect(throws: FigmaToolsError.self) {
            try FigmaReference.normalizeNodeID("1:2&ids=3")
        }
        #expect(throws: FigmaToolsError.missingFileReference) {
            try FigmaReference.resolve(url: nil, fileKey: " ", nodeID: "1:2")
        }
        #expect(throws: FigmaToolsError.self) {
            try FigmaReference.resolve(url: nil, fileKey: "../etc", nodeID: nil)
        }
    }
}

@Suite
struct FigmaCredentialStoreTests {
    private func makeSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FigmaCredentialStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private let credential = FigmaStoredCredential(
        accessToken: "figd_example",
        accountHandle: "Gerardo",
        accountEmail: "gerardo@example.com",
        signedInAt: Date(timeIntervalSince1970: 1_800_000_000)
    )

    @Test
    func loginRoundTripsInAPrivateStoreAndLogoutRemovesIt() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = FigmaCredentialStore(environment: ["ZENCODE_SUPPORT_DIRECTORY": support.path])
        #expect(store.fileURL.path.hasPrefix(support.standardizedFileURL.path))
        #expect(try store.load() == nil)

        try store.save(credential)
        #expect(try store.load() == credential)
        let fileMode = try #require(
            try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        )
        let directoryMode = try #require(
            try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        )
        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(credential.accountLabel == "Gerardo <gerardo@example.com>")

        #expect(try store.remove())
        #expect(try store.load() == nil)
        #expect(try !store.remove())
    }

    @Test
    func sharedOrCorruptStoresAreRejected() throws {
        let support = try makeSupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let store = FigmaCredentialStore(environment: ["ZENCODE_SUPPORT_DIRECTORY": support.path])

        try store.save(credential)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        #expect(throws: FigmaToolsError.self) { try store.load() }

        try Data("not json".utf8).write(to: store.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.fileURL.path)
        #expect(throws: FigmaToolsError.self) { try store.load() }
    }

    @Test
    func malformedTokensAreRejectedBeforeContactingFigma() async {
        #expect(!FigmaCredentialStore.isWellFormedToken("figd_a\r\nX-Evil: 1"))
        #expect(!FigmaCredentialStore.isWellFormedToken(""))
        #expect(FigmaCredentialStore.isWellFormedToken("figd_AbC-123_xyz"))

        guard case .failure = await FigmaLogin.verify(token: "   ") else {
            Issue.record("A blank token must be rejected.")
            return
        }
        guard case .failure = await FigmaLogin.verify(token: "two words") else {
            Issue.record("A token with spaces must be rejected.")
            return
        }
    }

    @Test
    func onlyTokenRejectionsTriggerANewSignIn() {
        #expect(isTokenRejection(status: 401, serverMessage: "Missing credentials"))
        #expect(isTokenRejection(status: 403, serverMessage: "Invalid token"))
        #expect(isTokenRejection(status: 403, serverMessage: "Token expired"))
        #expect(isTokenRejection(status: 403, serverMessage: "Invalid scope(s): file_content:read"))
        #expect(!isTokenRejection(status: 403, serverMessage: "Forbidden"))
        #expect(!isTokenRejection(status: 404, serverMessage: "Not found"))
    }

    @Test
    func sourceNoLongerReadsCredentialsFromTheEnvironment() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("FIGMA_ACCESS_TOKEN"), "\(url.lastPathComponent)")
            #expect(!text.contains("FIGMA_TOKEN"), "\(url.lastPathComponent)")
            checked += 1
        }
        #expect(checked > 0)
    }
}

@Suite
struct FigmaLoginServerTests {
    @Test
    func onlyLoopbackHostsAndOriginsAreAccepted() {
        #expect(FigmaLoginHTTP.isLoopbackHost("127.0.0.1:53682"))
        #expect(FigmaLoginHTTP.isLoopbackHost("localhost"))
        #expect(FigmaLoginHTTP.isLoopbackHost("[::1]:80"))
        #expect(!FigmaLoginHTTP.isLoopbackHost("evil.example:53682"))

        #expect(FigmaLoginHTTP.isLoopbackOrigin(nil))
        #expect(FigmaLoginHTTP.isLoopbackOrigin("http://127.0.0.1:53682"))
        #expect(!FigmaLoginHTTP.isLoopbackOrigin("null"))
        #expect(!FigmaLoginHTTP.isLoopbackOrigin("https://evil.example"))
    }

    @Test
    func formTokensAreRandomAndComparedExactly() {
        let token = FigmaLoginHTTP.makeFormToken()
        #expect(token.count == 64)
        #expect(token != FigmaLoginHTTP.makeFormToken())
        #expect(FigmaLoginHTTP.constantTimeEquals(token, token))
        #expect(!FigmaLoginHTTP.constantTimeEquals(token, String(token.dropLast()) + "x"))
        #expect(!FigmaLoginHTTP.constantTimeEquals("", ""))
    }

    @Test
    func formPostsAreParsed() throws {
        let raw = "POST /?x=1 HTTP/1.1\r\nHost: 127.0.0.1:5000\r\nOrigin: http://127.0.0.1:5000\r\nContent-Length: 31\r\n\r\nstate=abc&token=figd_a%2Bb+c%3D"
        let request = try #require(FigmaLoginHTTP.parse(Data(raw.utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/")
        #expect(request.isComplete)
        let fields = FigmaLoginHTTP.parseFormURLEncoded(request.body)
        #expect(fields["state"] == "abc")
        #expect(fields["token"] == "figd_a+b c=")
    }

    @Test
    func pagesEscapeDynamicText() {
        let page = FigmaLoginPage.form(
            reason: .rejected("<script>alert(1)</script>"),
            error: "\"quoted\"",
            formToken: "tok\"en"
        )
        #expect(!page.contains("<script>alert(1)</script>"))
        #expect(page.contains("&lt;script&gt;"))
        #expect(page.contains("value=\"tok&quot;en\""))
        #expect(FigmaLoginPage.success(accountLabel: "A <b>").contains("A &lt;b&gt;"))
    }
}

@Suite
struct FigmaFormatTests {
    @Test
    func numbersAndColorsAreCompact() throws {
        #expect(FigmaFormat.number(12) == "12")
        #expect(FigmaFormat.number(0.5) == "0.5")
        #expect(FigmaFormat.number(-3.256) == "-3.26")
        #expect(FigmaFormat.hex(try json(#"{"r":1,"g":1,"b":1,"a":1}"#)) == "#FFFFFF")
        #expect(FigmaFormat.hex(try json(#"{"r":0,"g":0,"b":0,"a":1}"#), opacity: 0.5) == "#00000080")
    }

    @Test
    func paintsSkipHiddenEntriesAndDescribeGradients() throws {
        let paints = try json(#"""
        [
          {"type":"SOLID","visible":false,"color":{"r":1,"g":0,"b":0,"a":1}},
          {"type":"GRADIENT_LINEAR","gradientStops":[
            {"position":0,"color":{"r":1,"g":0,"b":0,"a":1}},
            {"position":1,"color":{"r":0,"g":0,"b":1,"a":1}}
          ]}
        ]
        """#)
        #expect(FigmaFormat.paints(paints) == ["linear-gradient(#FF0000 0%, #0000FF 100%)"])
    }

    @Test
    func budgetStopsAtItsLimit() {
        var budget = FigmaTextBudget(limit: 10)
        let firstAccepted = budget.append("12345")
        let secondAccepted = budget.append("123456")
        #expect(firstAccepted)
        #expect(!secondAccepted)
        #expect(budget.isExhausted)
        #expect(budget.text == "12345")
    }
}

@Suite
struct FigmaRendererTests {
    private let sample = #"""
    {
      "document": {
        "id": "1:2", "name": "Card", "type": "FRAME",
        "absoluteBoundingBox": {"x": 100, "y": 200, "width": 320, "height": 120},
        "layoutMode": "VERTICAL", "itemSpacing": 8,
        "paddingTop": 16, "paddingRight": 24, "paddingBottom": 16, "paddingLeft": 24,
        "counterAxisAlignItems": "CENTER",
        "cornerRadius": 12,
        "fills": [{"type": "SOLID", "color": {"r": 1, "g": 1, "b": 1, "a": 1}}],
        "styles": {"fill": "S:surface"},
        "children": [
          {
            "id": "1:3", "name": "Title <b>", "type": "TEXT",
            "absoluteBoundingBox": {"x": 124, "y": 216, "width": 272, "height": 24},
            "characters": "Hello",
            "style": {"fontFamily": "Inter", "fontStyle": "Semi Bold", "fontWeight": 600, "fontSize": 16, "lineHeightPx": 24, "lineHeightUnit": "PIXELS", "letterSpacing": 0},
            "styles": {"text": "S:heading"},
            "fills": [{"type": "SOLID", "color": {"r": 0, "g": 0, "b": 0, "a": 1}, "boundVariables": {"color": {"type": "VARIABLE_ALIAS", "id": "VariableID:1:9"}}}]
          },
          {
            "id": "1:4", "name": "Button", "type": "INSTANCE", "componentId": "C:1",
            "absoluteBoundingBox": {"x": 124, "y": 256, "width": 100, "height": 40},
            "componentProperties": {"Size": {"type": "VARIANT", "value": "Large"}, "Label#12:0": {"type": "TEXT", "value": "OK"}},
            "itemSpacing": 4, "boundVariables": {"itemSpacing": {"type": "VARIABLE_ALIAS", "id": "VariableID:2:1"}}
          }
        ]
      },
      "components": {"C:1": {"key": "abc", "name": "Button/Primary", "description": "Main action"}},
      "styles": {
        "S:surface": {"name": "Surface/Default", "styleType": "FILL"},
        "S:heading": {"name": "Heading/H3", "styleType": "TEXT"}
      }
    }
    """#

    @Test
    func metadataUsesParentRelativeCoordinatesAndEscapesNames() throws {
        let entry = try json(sample)
        var budget = FigmaTextBudget()
        FigmaMetadataRenderer.render(try #require(entry["document"]), parentBox: nil, budget: &budget)
        #expect(budget.text == """
        <frame id="1:2" name="Card" x="100" y="200" width="320" height="120">
          <text id="1:3" name="Title &lt;b&gt;" x="24" y="16" width="272" height="24" />
          <instance id="1:4" name="Button" x="24" y="56" width="100" height="40" />
        </frame>
        """)
    }

    @Test
    func designContextDescribesLayoutTypographyInstancesAndStyles() throws {
        var budget = FigmaTextBudget()
        FigmaDesignContextRenderer.render(entry: try json(sample), budget: &budget)
        let text = budget.text
        #expect(text.contains("- FRAME \"Card\" [1:2] 320x120 at (100, 200)"))
        #expect(text.contains("auto-layout: column, gap 8, padding 16 24 16 24, main-axis start, cross-axis center"))
        #expect(text.contains("fill: #FFFFFF (style \"Surface/Default\")"))
        #expect(text.contains("radius: 12"))
        #expect(text.contains("text: \"Hello\""))
        #expect(text.contains("font: Inter Semi Bold 600, 16px/24px (style \"Heading/H3\")"))
        #expect(text.contains("instance of \"Button/Primary\" with Label=OK, Size=Large"))
        #expect(text.contains("- Button/Primary [C:1] key abc: Main action"))
        #expect(text.contains("- Heading/H3 (text)"))
    }

    @Test
    func variableCollectorResolvesNamesWhenTheVariablesAPIAnswers() throws {
        let entry = try json(sample)
        var collector = FigmaVariableCollector()
        collector.collect(try #require(entry["document"]))
        #expect(collector.variables.map(\.id) == ["VariableID:1:9", "VariableID:2:1"])

        let variables = try json(#"""
        {"meta": {
          "variableCollections": {"VC:1": {"name": "Tokens", "defaultModeId": "M:1"}},
          "variables": {
            "VariableID:1:9": {"name": "color/text", "resolvedType": "COLOR", "variableCollectionId": "VC:1",
                               "valuesByMode": {"M:1": {"type": "VARIABLE_ALIAS", "id": "VariableID:3:3"}}},
            "VariableID:3:3": {"name": "palette/black", "resolvedType": "COLOR", "variableCollectionId": "VC:1",
                               "valuesByMode": {"M:1": {"r": 0, "g": 0, "b": 0, "a": 1}}}
          }
        }}
        """#)
        let resolved = collector.definitions(
            stylesMetadata: entry["styles"]?.objectValue ?? [:],
            variablesResponse: variables
        )
        #expect(resolved.definitions["Surface/Default"] == "#FFFFFF")
        #expect(resolved.definitions["Heading/H3"]?.hasPrefix("Font(family: \"Inter\", style: Semi Bold, size: 16, weight: 600") == true)
        #expect(resolved.definitions["color/text"] == "#000000")
        #expect(resolved.definitions["VariableID:2:1 (itemSpacing)"] == "4")
        #expect(resolved.unresolvedVariableCount == 1)
    }
}

@Suite
struct FigmaScreenshotTests {
    @Test
    func pngDimensionsAreReadFromTheHeader() throws {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]
        bytes += [0, 0, 0x01, 0x40, 0, 0, 0, 0xF0]
        let dimensions = try FigmaGetScreenshotTool.validateImage(Data(bytes), format: "png")
        #expect(dimensions?.width == 320)
        #expect(dimensions?.height == 240)

        #expect(throws: FigmaToolsError.self) {
            try FigmaGetScreenshotTool.validateImage(Data("<html>".utf8), format: "png")
        }
    }

    @Test
    func toolNamesKeepTheFigmaPrefix() {
        let names = [
            FigmaGetDesignContextTool.name,
            FigmaGetMetadataTool.name,
            FigmaGetScreenshotTool.name,
            FigmaGetVariableDefsTool.name,
            FigmaWhoAmITool.name,
            FigmaLoginTool.name,
            FigmaLogoutTool.name
        ]
        #expect(names.allSatisfy { $0.hasPrefix("figma.") })
        #expect(Set(names).count == names.count)
    }
}

/// Socket layers the sign-in server can run on. `.nio` is also exercised on
/// macOS, where the platform default is the Network framework.
enum FigmaLoginTestTransport: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case platformDefault
    case nio

    static var available: [FigmaLoginTestTransport] {
        #if os(macOS)
        [.platformDefault, .nio]
        #else
        [.platformDefault]
        #endif
    }

    var testDescription: String { rawValue }

    func makeServer(
        reason: FigmaLoginReason = .notSignedIn,
        validate: @escaping FigmaLoginServer.Validator
    ) throws -> FigmaLoginServer {
        switch self {
        case .platformDefault:
            return try FigmaLoginServer(reason: reason, validate: validate)
        case .nio:
            return try FigmaLoginServer(reason: reason, transport: FigmaLoginNIOTransport(), validate: validate)
        }
    }
}

private final class FigmaLoginCallCounter: Sendable {
    private let value = Mutex(0)

    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

@Suite
struct FigmaLoginServerFlowTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        return URLSession(configuration: configuration)
    }

    private func post(
        port: UInt16,
        fields: String,
        origin: String
    ) async throws -> (status: Int, body: String) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = Data(fields.utf8)
        let (data, response) = try await makeSession().data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    @Test(arguments: FigmaLoginTestTransport.available)
    func signInPageAcceptsOnlyItsOwnFormAndResolvesWithTheVerifiedLogin(transport: FigmaLoginTestTransport) async throws {
        let expected = FigmaStoredCredential(
            accessToken: "figd_good",
            accountHandle: "Gerardo",
            accountEmail: nil,
            signedInAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let server = try transport.makeServer { token in
            token == "figd_good"
                ? .success(expected)
                : .failure(FigmaLoginValidationError(message: "Figma did not accept this token."))
        }
        defer { server.stop() }
        let port = try await server.start()
        let origin = "http://127.0.0.1:\(port)"

        let (pageData, _) = try await makeSession().data(from: URL(string: "\(origin)/")!)
        let page = String(decoding: pageData, as: UTF8.self)
        #expect(page.contains("Sign in to Figma"))
        #expect(page.contains("value=\"\(server.formToken)\""))

        let wrongState = try await post(port: port, fields: "state=nope&token=figd_good", origin: origin)
        #expect(wrongState.status == 403)

        let foreignOrigin = try await post(
            port: port,
            fields: "state=\(server.formToken)&token=figd_good",
            origin: "https://evil.example"
        )
        #expect(foreignOrigin.status == 403)

        let rejected = try await post(port: port, fields: "state=\(server.formToken)&token=figd_bad", origin: origin)
        #expect(rejected.status == 200)
        #expect(rejected.body.contains("Figma did not accept this token."))

        let accepted = try await post(port: port, fields: "state=\(server.formToken)&token=figd_good", origin: origin)
        #expect(accepted.status == 200)
        #expect(accepted.body.contains("Connected as Gerardo."))

        let result = try await server.waitForResult(timeout: 5)
        #expect(result == expected)
    }

    @Test(arguments: FigmaLoginTestTransport.available)
    func oversizedRequestsNeverReachTheSignInFlow(transport: FigmaLoginTestTransport) async throws {
        let calls = FigmaLoginCallCounter()
        let server = try transport.makeServer { _ in
            calls.increment()
            return .failure(FigmaLoginValidationError(message: "unexpected"))
        }
        defer { server.stop() }
        let port = try await server.start()

        let padding = String(repeating: "a", count: FigmaLoginServer.maximumRequestSize * 2)
        do {
            let response = try await post(
                port: port,
                fields: "state=\(server.formToken)&token=\(padding)",
                origin: "http://127.0.0.1:\(port)"
            )
            #expect(response.status == 413)
        } catch {
            // The server may close the connection while the client is still
            // sending; what matters is that nothing was verified.
        }
        #expect(calls.count == 0)
    }

    @Test(arguments: FigmaLoginTestTransport.available)
    func stoppingTheServerClosesTheListenerAndFailsTheWaiter(transport: FigmaLoginTestTransport) async throws {
        let server = try transport.makeServer { _ in
            .failure(FigmaLoginValidationError(message: "unexpected"))
        }
        defer { server.stop() }
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        let session = makeSession()

        let (_, reachable) = try await session.data(from: url)
        #expect((reachable as? HTTPURLResponse)?.statusCode == 200)

        let waiter = Task { try await server.waitForResult(timeout: 30) }
        server.stop()
        await #expect(throws: CancellationError.self) { try await waiter.value }

        var isClosed = false
        for _ in 0 ..< 50 {
            if (try? await session.data(from: url)) == nil {
                isClosed = true
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(isClosed, "The listener still accepted connections after stop().")
    }
}
