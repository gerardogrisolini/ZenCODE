import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// One TLS context per trust configuration, rebuilt after its time to live.
@Suite
struct RemoteTransportTLSContextCacheTests {
    @Test
    func sameTrustConfigurationReusesTheContext() async throws {
        await Task.yield()
        let cache = RemoteTransportTLSContextCache()
        let first = try cache.context(for: .systemDefault)
        // `serverName` is applied per handler, not per context.
        let second = try cache.context(for: RemoteTransportTLSConfiguration(serverName: "sni.example.com"))
        #expect(first === second)
        #expect(cache.count == 1)
    }

    @Test
    func differentTrustConfigurationsDoNotShareAContext() async throws {
        await Task.yield()
        let cache = RemoteTransportTLSContextCache()
        let system = try cache.context(for: .systemDefault)
        let custom = try cache.context(for: RemoteTransportTLSConfiguration(additionalTrustRootPEMs: [Self.root]))
        #expect(system !== custom)
        #expect(cache.count == 2)
    }

    @Test
    func anEntryExpiresAfterItsTimeToLive() async throws {
        await Task.yield()
        let instant = Mutex(ContinuousClock.now)
        let cache = RemoteTransportTLSContextCache(now: { instant.withLock { $0 } })
        let first = try cache.context(for: .systemDefault)
        instant.withLock { $0 = $0.advanced(by: .seconds(599)) }
        #expect(try cache.context(for: .systemDefault) === first)
        instant.withLock { $0 = $0.advanced(by: .seconds(1)) }
        #expect(try cache.context(for: .systemDefault) !== first)
        #expect(cache.count == 1)
    }

    /// A throwaway self-signed P-256 root (public certificate, no key).
    private static let root = Data("""
        -----BEGIN CERTIFICATE-----
        MIIBlTCCATygAwIBAgIUIIe+7qn8ASKlC2OQKi6QllmUOn8wCgYIKoZIzj0EAwIw
        MDEuMCwGA1UEAwwlWmVuQ09ERSBUTFMgY29udGV4dCBjYWNoZSB0ZXN0IHJvb3Qg
        QTAgFw0yNjExMTAwMTEzMDBaGA8yMTI2MTAxNzAxMTMwMFowMDEuMCwGA1UEAwwl
        WmVuQ09ERSBUTFMgY29udGV4dCBjYWNoZSB0ZXN0IHJvb3QgQTBZMBMGByqGSM49
        AgEGCCqGSM49AwEHA0IABH/UmjeOAK+yhoIQ+gqSl8XRKmYx+ffT4UBOs0eddtoj
        TnQtsfkOWZZ6KUkCcu4LvxR28Jz82r3+M3117masK02jMjAwMB0GA1UdDgQWBBQ3
        66CvhSlNTccPA+6m22E9OA8bWTAPBgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMC
        A0cAMEQCIBrzmKOCDbALy6LRjENeXIRIL7u08WfNxCY1hLR7FKoHAiBDyYNc09Cy
        m4YVjfkEzFFKDQp23gIdXYT8mLOdQ5N42g==
        -----END CERTIFICATE-----

        """.utf8)
}
