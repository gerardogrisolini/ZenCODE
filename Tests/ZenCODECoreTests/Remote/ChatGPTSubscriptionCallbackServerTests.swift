//
//  ChatGPTSubscriptionCallbackServerTests.swift
//  ZenCODECoreTests
//
//  Loopback-only binding and spurious-request tolerance for the ChatGPT OAuth
//  callback listener.
//

#if os(macOS)
import Foundation
import Network
import Testing
@testable import ZenCODECore

@Suite("ChatGPT Subscription callback server", .serialized)
struct ChatGPTSubscriptionCallbackServerTests {
    private static let state = "expected-state"

    @Test("request decision only completes for the expected state")
    func callbackDecision() {
        let server = ChatGPTSubscriptionCallbackServer(state: Self.state, port: 0)
        func decide(_ request: String?) -> ChatGPTSubscriptionCallbackServer.CallbackRequestDecision {
            server.callbackDecision(for: request.map { Data($0.utf8) })
        }

        #expect(decide("GET /auth/callback?code=abc&state=\(Self.state) HTTP/1.1\r\nHost: localhost\r\n\r\n")
            == .authorized(code: "abc"))
        #expect(decide("GET /favicon.ico HTTP/1.1\r\n\r\n") == .notFound)
        for spurious in [
            nil,
            "",
            "garbage",
            "\u{1}\u{2}\u{3}",
            "GET /auth/callback?code=abc HTTP/1.1\r\n\r\n",
            "GET /auth/callback?code=abc&state=attacker HTTP/1.1\r\n\r\n",
            "GET /auth/callback?error=access_denied HTTP/1.1\r\n\r\n"
        ] {
            let decision = decide(spurious)
            guard case .invalid = decision else {
                Issue.record("Expected \(String(describing: spurious)) to be ignored, got \(decision)")
                continue
            }
            #expect(decision.statusCode == 400)
        }
        let authentic = decide("GET /auth/callback?error=access_denied&state=\(Self.state) HTTP/1.1\r\n\r\n")
        guard case .authenticFailure = authentic else {
            Issue.record("Expected an authentic failure, got \(authentic)")
            return
        }
        #expect(authentic.statusCode == 400)
    }

    @Test("listener parameters are restricted to loopback")
    func loopbackParameters() {
        for host in [NWEndpoint.Host.ipv4(.loopback), .ipv6(.loopback)] {
            let parameters = ChatGPTSubscriptionCallbackServer.loopbackParameters(host: host, port: 1455)
            #expect(parameters.acceptLocalOnly)
            #expect(parameters.allowLocalEndpointReuse)
            #expect(parameters.requiredLocalEndpoint == .hostPort(host: host, port: 1455))
        }
    }

    @Test("spurious requests get 400 and the valid callback still completes", arguments: ["127.0.0.1", "[::1]"])
    func spuriousRequestsDoNotTerminateSignIn(host: String) async throws {
        let server = ChatGPTSubscriptionCallbackServer(state: Self.state, port: 0)
        try await server.start()
        defer { Task { await server.stop() } }

        let endpoints = await server.boundLocalEndpoints()
        for endpoint in endpoints {
            guard case let .hostPort(boundHost, _) = endpoint else {
                Issue.record("Unexpected endpoint \(endpoint)")
                continue
            }
            #expect(boundHost == .ipv4(.loopback) || boundHost == .ipv6(.loopback))
        }
        #expect(endpoints.contains { endpoint in
            if case .hostPort(.ipv4(.loopback), _) = endpoint { return true }
            return false
        })
        if host.hasPrefix("["), endpoints.count < 2 {
            // IPv6 loopback is best effort (disabled on this host).
            return
        }
        let port = try #require(await server.boundPort())

        // Raw garbage over TCP, a wrong state and a missing state are all
        // rejected with 400 without ending the flow.
        #expect(try await Self.rawRequest("garbage\r\n\r\n", host: host, port: port).hasPrefix("HTTP/1.1 400"))
        #expect(try await Self.status(host: host, port: port, query: "code=evil&state=attacker") == 400)
        #expect(try await Self.status(host: host, port: port, query: "code=evil") == 400)
        #expect(try await Self.status(host: host, port: port, path: "/other", query: "") == 404)

        #expect(try await Self.status(host: host, port: port, query: "code=good&state=\(Self.state)") == 200)
        let code = try await server.waitForCode()
        #expect(code == "good")
    }

    private static func status(
        host: String,
        port: UInt16,
        path: String = "/auth/callback",
        query: String
    ) async throws -> Int {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://\(host):\(port)\(path)?\(query)"))
        let (_, response) = try await session.data(from: url)
        return try #require(response as? HTTPURLResponse).statusCode
    }

    private static func rawRequest(_ payload: String, host: String, port: UInt16) async throws -> String {
        let hostName = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let connection = NWConnection(
            host: NWEndpoint.Host(hostName),
            port: try #require(NWEndpoint.Port(rawValue: port)),
            using: .tcp
        )
        defer { connection.cancel() }
        let queue = DispatchQueue(label: "ChatGPTSubscriptionCallbackServerTests.raw")
        connection.start(queue: queue)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(payload.utf8), completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
