import Foundation
import Testing

#if os(macOS)
@testable import jira_tools_feature

@Suite
struct JiraHTTPSOnlyConfigurationTests {
    // MARK: - Site URL normalization

    @Test
    func acceptsHTTPSAndDefaultsMissingSchemeToHTTPS() throws {
        let explicit = try JiraStoredConfiguration(
            siteURLString: "https://example.atlassian.net",
            email: "person@example.com"
        )
        #expect(explicit.siteURL.scheme == "https")
        #expect(explicit.siteURL.host == "example.atlassian.net")

        let schemeless = try JiraStoredConfiguration(
            siteURLString: "example.atlassian.net",
            email: "person@example.com"
        )
        #expect(schemeless.siteURL.scheme == "https")
        #expect(schemeless.siteURL.host == "example.atlassian.net")
    }

    @Test
    func upperCaseHTTPSIsAcceptedAndNormalized() throws {
        let configuration = try JiraStoredConfiguration(
            siteURLString: "HTTPS://Example.Atlassian.NET",
            email: "person@example.com"
        )
        // Foundation preserves host case; only the scheme is normalized, and
        // the host is compared case-insensitively at request time.
        #expect(configuration.siteURL.scheme == "https")
        #expect(configuration.siteURL.host?.lowercased() == "example.atlassian.net")
    }

    @Test
    func rejectsHTTPSiteURLWithExplicitGuidance() {
        #expect(throws: JiraToolsError.self) {
            _ = try JiraStoredConfiguration(
                siteURLString: "http://example.atlassian.net",
                email: "person@example.com"
            )
        }
        do {
            _ = try JiraStoredConfiguration(
                siteURLString: "http://example.atlassian.net",
                email: "person@example.com"
            )
        } catch let error as JiraToolsError {
            let message = error.localizedDescription
            #expect(message.contains("HTTPS"))
            #expect(message.contains("https://example.atlassian.net"))
            #expect(message.contains("unencrypted"))
        } catch {
            Issue.record("Expected JiraToolsError, got \(error)")
        }
    }

    @Test
    func rejectsUnsupportedSchemes() {
        let unsupported = ["ftp://example.atlassian.net", "file:///etc/hosts", "gopher://example.com"]
        for value in unsupported {
            #expect(throws: JiraToolsError.self) {
                _ = try JiraStoredConfiguration(siteURLString: value, email: "person@example.com")
            }
        }
    }

    @Test
    func rejectsURLsWithoutHostAndEmbeddedCredentials() {
        #expect(throws: JiraToolsError.self) {
            _ = try JiraStoredConfiguration(siteURLString: "https://", email: "person@example.com")
        }
        #expect(throws: JiraToolsError.self) {
            _ = try JiraStoredConfiguration(siteURLString: "not a url", email: "person@example.com")
        }
        #expect(throws: JiraToolsError.self) {
            _ = try JiraStoredConfiguration(
                siteURLString: "https://user:pass@example.atlassian.net",
                email: "person@example.com"
            )
        }
    }

    @Test
    func normalizationStripsPathQueryAndFragment() throws {
        let configuration = try JiraStoredConfiguration(
            siteURLString: "https://example.atlassian.net/browse/PROJ-1?tab=details#anchor",
            email: "person@example.com"
        )
        #expect(configuration.siteURL.absoluteString == "https://example.atlassian.net")
    }

    // MARK: - Stored configuration (decoding path)

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("JiraHTTPSOnly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test
    func storedHTTPConfigurationFailsWithExplicitGuidance() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = #"{"siteURLString":"http://example.atlassian.net","email":"person@example.com"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("jira.json"))

        setenv("ZENCODE_SUPPORT_DIRECTORY", directory.path, 1)
        defer { unsetenv("ZENCODE_SUPPORT_DIRECTORY") }

        do {
            _ = try JiraConfigurationStore.load()
            Issue.record("Expected load() to reject a stored http:// site URL")
        } catch let error as JiraToolsError {
            let message = error.localizedDescription
            #expect(message.contains("http://example.atlassian.net"))
            #expect(message.contains("https://example.atlassian.net"))
        } catch {
            Issue.record("Expected JiraToolsError, got \(error)")
        }
    }

    @Test
    func storedHTTPSConfigurationDecodes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let json = #"{"siteURLString":"https://example.atlassian.net","email":"person@example.com"}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent("jira.json"))

        setenv("ZENCODE_SUPPORT_DIRECTORY", directory.path, 1)
        defer { unsetenv("ZENCODE_SUPPORT_DIRECTORY") }

        let configuration = try JiraConfigurationStore.load()
        #expect(configuration.siteURL.scheme == "https")
        #expect(configuration.siteURL.host == "example.atlassian.net")
    }

    @Test
    func configurationStoreRoundTripPreservesHTTPS() throws {
        let configuration = try JiraStoredConfiguration(
            siteURLString: "example.atlassian.net",
            email: "person@example.com"
        )
        let encoder = JSONEncoder()
        let data = try encoder.encode(configuration)
        let decoded = try JSONDecoder().decode(JiraStoredConfiguration.self, from: data)
        #expect(decoded.siteURL.scheme == "https")
        #expect(decoded.siteURLString == "https://example.atlassian.net")
    }
}

@Suite
struct JiraHTTPSOnlyRequestGuardTests {
    @Test
    func requireHTTPSAcceptsHTTPSAndRejectsEverythingElse() throws {
        try JiraRESTService.requireHTTPS(URL(string: "https://example.atlassian.net/rest/api/3/myself")!)

        for raw in [
            "http://example.atlassian.net/rest/api/3/myself",
            "ftp://example.atlassian.net/rest",
            "file:///etc/hosts"
        ] {
            #expect(throws: JiraToolsError.self) {
                try JiraRESTService.requireHTTPS(URL(string: raw)!)
            }
        }
    }

    @Test
    func redirectPolicyAllowsExactSameOriginOverHTTPS() {
        let siteHost = "example.atlassian.net"
        let origin = URL(string: "https://example.atlassian.net/rest/api/3/myself")!
        let allowed = [
            "https://example.atlassian.net/rest/api/3/myself",
            "https://example.atlassian.net./rest/api/3/myself",
            "https://EXAMPLE.ATLASSIAN.NET/rest/api/3/myself"
        ]
        for raw in allowed {
            #expect(
                JiraRedirectPolicy.allowsRedirect(siteHost: siteHost, from: origin, to: URL(string: raw)!),
                "Expected redirect to \(raw) to be allowed"
            )
        }
    }

    @Test
    func redirectPolicyBlocksCrossOriginAndDowngrades() {
        let siteHost = "example.atlassian.net"
        let origin = URL(string: "https://example.atlassian.net/rest/api/3/myself")!
        let blocked = [
            "https://api.example.atlassian.net/rest",
            "https://evil.example.net/rest",
            "https://atlassian.net/rest",
            "http://example.atlassian.net/rest",
            "https://notexample.atlassian.net.evil.com/rest",
            "https://example.atlassian.net.evil.com/rest"
        ]
        for raw in blocked {
            #expect(
                !JiraRedirectPolicy.allowsRedirect(siteHost: siteHost, from: origin, to: URL(string: raw)!),
                "Expected redirect to \(raw) to be blocked"
            )
        }
    }

    @Test
    func redirectPolicyComparesEffectivePorts() {
        let siteHost = "example.atlassian.net"
        let defaultPortOrigin = URL(string: "https://example.atlassian.net/rest")!

        // An omitted HTTPS port and an explicit 443 have the same effective
        // origin port.
        #expect(JiraRedirectPolicy.allowsRedirect(
            siteHost: siteHost,
            from: defaultPortOrigin,
            to: URL(string: "https://example.atlassian.net:443/rest")!
        ))
        #expect(!JiraRedirectPolicy.allowsRedirect(
            siteHost: siteHost,
            from: defaultPortOrigin,
            to: URL(string: "https://example.atlassian.net:8443/rest")!
        ))

        let alternatePortOrigin = URL(string: "https://example.atlassian.net:8443/rest")!
        #expect(JiraRedirectPolicy.allowsRedirect(
            siteHost: siteHost,
            from: alternatePortOrigin,
            to: URL(string: "https://example.atlassian.net:8443/rest")!
        ))
        #expect(!JiraRedirectPolicy.allowsRedirect(
            siteHost: siteHost,
            from: alternatePortOrigin,
            to: URL(string: "https://example.atlassian.net/rest")!
        ))
    }

    @Test
    func redirectPolicyFailsClosedOnMissingComponents() {
        let siteHost = "example.atlassian.net"
        let origin = URL(string: "https://example.atlassian.net")!
        #expect(!JiraRedirectPolicy.allowsRedirect(
            siteHost: siteHost,
            from: origin,
            to: URL(string: "/relative")!
        ))
        // A blank stored host must never authorize a redirect target.
        #expect(!JiraRedirectPolicy.allowsRedirect(
            siteHost: "",
            from: origin,
            to: URL(string: "https://example.atlassian.net/rest")!
        ))
    }

    /// The delegate decision is fully delegated to `JiraRedirectPolicy`, so
    /// the pure-function suites above cover both the same-origin allowance and
    /// the cross-origin / TLS-downgrade refusals that protect the Basic
    /// credentials during real redirects.
}
#endif
