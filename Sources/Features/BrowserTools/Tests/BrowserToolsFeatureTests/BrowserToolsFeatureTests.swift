import Foundation
@testable import BrowserToolsFeature
import FeatureKit
import Testing

@Suite
struct BrowserToolsFeatureTests {
    @Test
    func browserURLPolicyAllowsPublicAndLoopbackDestinations() throws {
        let policy = BrowserURLPolicy(environment: [:])

        #expect(try policy.validate("https://example.com/path?q=1").host == "example.com")
        #expect(try policy.validate("http://localhost:8080").host == "localhost")
        #expect(try policy.validate("http://127.0.0.1:3000").host == "127.0.0.1")
        #expect(try policy.validate("http://[::1]:8080").host == "::1")
    }

    @Test
    func browserLoopbackAuthorizationCoversCurrentAndExplicitLocalPages() {
        #expect(BrowserToolsRunner.resolvedLoopbackAuthorization(
            currentPageURL: "http://127.0.0.1:3000/app",
            explicitlyRequestedDestinationIsLoopback: false,
            environment: [:]
        ))
        #expect(BrowserToolsRunner.resolvedLoopbackAuthorization(
            currentPageURL: "https://example.com/",
            explicitlyRequestedDestinationIsLoopback: true,
            environment: [:]
        ))
        #expect(!BrowserToolsRunner.resolvedLoopbackAuthorization(
            currentPageURL: "https://example.com/",
            explicitlyRequestedDestinationIsLoopback: false,
            environment: [:]
        ))
    }

    @Test
    func browserURLPolicyRejectsUnsafeAndAmbiguousDestinations() {
        let policy = BrowserURLPolicy(environment: [:])

        #expect(throws: BrowserURLPolicyError.unsupportedScheme("file")) {
            try policy.validate("file:///tmp/private")
        }
        #expect(throws: BrowserURLPolicyError.credentialsNotAllowed("https://user:secret@example.com")) {
            try policy.validate("https://user:secret@example.com")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validate("http://10.0.0.1")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("169.254.169.254")) {
            try policy.validate("http://169.254.169.254/latest/meta-data")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("0177.0.0.1")) {
            try policy.validate("http://0177.0.0.1")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("service.local")) {
            try policy.validate("https://service.local")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("service.local.")) {
            try policy.validate("https://service.local.")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("[fe90::1]")) {
            try policy.validate("http://[fe90::1]")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("[fec0::1]")) {
            try policy.validate("http://[fec0::1]")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("[ff02::1]")) {
            try policy.validate("http://[ff02::1]")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("[::ffff:a00:1]")) {
            try policy.validate("http://[::ffff:a00:1]")
        }
    }

    @Test
    func browserNetworkRequestPolicyRejectsResolvedPrivateDestinations() throws {
        let resolver = StaticBrowserHostResolver(addressesByHost: [
            "public.example": ["10.0.0.1"],
            "mixed.example": ["93.184.216.34", "fd00::1"],
            "rebound.example": ["127.0.0.1"],
            "safe.example": ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
            "localhost": ["127.0.0.1", "::1"],
        ])
        let policy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: resolver
        )

        #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try policy.validateRequestURL("https://public.example/app")
        }
        #expect(throws: BrowserURLPolicyError.restrictedHost("fd00::1")) {
            try policy.validateRequestURL("https://mixed.example/app")
        }
        #expect(throws: BrowserNetworkGuardError.self) {
            try policy.validateRequestURL("https://rebound.example/app")
        }
        #expect(throws: BrowserNetworkGuardError.self) {
            try policy.validateRequestURL("ws://localhost:3000/hmr")
        }
        try policy.validateRequestURL("https://safe.example/app")
        try policy.validateRequestURL("about:blank")
        #expect(throws: BrowserNetworkGuardError.self) {
            try policy.validateRequestURL("file:///private/file")
        }

        let localDevelopmentPolicy = BrowserNetworkRequestPolicy(
            urlPolicy: BrowserURLPolicy(environment: [:]),
            resolver: resolver,
            allowsLoopback: true
        )
        try localDevelopmentPolicy.validateRequestURL("ws://localhost:3000/hmr")
        #expect(throws: BrowserNetworkGuardError.self) {
            try localDevelopmentPolicy.validateRequestURL("https://rebound.example/app")
        }
    }

    @Test
    func browserURLPolicyPrivateNetworkOverrideIsHostControlled() throws {
        let policy = BrowserURLPolicy(environment: [
            "ZENCODE_BROWSER_ALLOW_PRIVATE_NETWORK": "true"
        ])

        #expect(try policy.validate("http://10.0.0.1:8080").host == "10.0.0.1")
        #expect(try policy.validate("https://service.local").host == "service.local")
    }

    @Test
    func googleConsentClickIsLimitedToGoogleOwnedOrigin() {
        #expect(BrowserGoogleConsentOriginPolicy.allows(host: "google.com"))
        #expect(BrowserGoogleConsentOriginPolicy.allows(host: "consent.google.com"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "google.com.evil.example"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "notgoogle.com"))
        #expect(!BrowserGoogleConsentOriginPolicy.allows(host: "www.google.it"))
    }

    @Test
    func browserOpenValidatesDestinationBeforeLaunchingChrome() async {
        let tool = AnyFeatureTool(BrowserOpenTool())
        let context = FeatureContext(environment: [:])

        await #expect(throws: BrowserURLPolicyError.restrictedHost("10.0.0.1")) {
            try await tool.invoke(
                inputData: Data(#"{"url":"http://10.0.0.1"}"#.utf8),
                context: context
            )
        }
    }
}
