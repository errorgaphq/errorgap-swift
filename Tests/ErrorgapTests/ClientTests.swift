import Foundation
import Testing
@testable import Errorgap

@Suite(.serialized)
struct ClientTests {
    init() {
        FakeIngestorProtocol.reset()
    }

    @Test func postsToNoticesWithCanonicalHeaders() {
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            apiKey: "flk_test",
            async: false
        )
        let client = ErrorgapClient(cfg, session: session)
        let result = client.notify(NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "boom"]))
        #expect(result.success)

        let reqs = FakeIngestorProtocol.requests
        #expect(reqs.count == 1)
        #expect(reqs[0].method == "POST")
        #expect(reqs[0].url?.path == "/api/projects/demo/notices")
        #expect(reqs[0].headers["x-errorgap-project-key"] == "flk_test")
        #expect(reqs[0].headers["user-agent"]?.hasPrefix("errorgap-swift/") == true)
    }

    @Test func sendsFullNoticeEnvelope() {
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            apiKey: "flk_test",
            async: false
        )
        let client = ErrorgapClient(cfg, session: session)
        client.notify(NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "kaboom"]))

        let body = FakeIngestorProtocol.requests[0].body!
        #expect(body["errors"] != nil)
        #expect(body["context"] != nil)
    }

    @Test func rejectsMissingProjectSlug() {
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(endpoint: "https://errorgap.example.com")
        let client = ErrorgapClient(cfg, session: session)
        let result = client.notify(NSError(domain: "test", code: 0))
        #expect(result.error as? ErrorgapError == .missingProjectSlug)
        #expect(FakeIngestorProtocol.requests.count == 0)
    }
}
