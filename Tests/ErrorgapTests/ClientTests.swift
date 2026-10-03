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

    @Test func sendsApmTransactionsAndNormalizesSQL() {
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            async: false,
            apmEnabled: true
        )
        let client = ErrorgapClient(cfg, session: session)
        let result = client.notifyTransaction(ErrorgapTransaction(
            method: "POST",
            path: "/orders/{id}",
            statusCode: 201,
            durationMs: 42.5,
            spans: [.database("SELECT * FROM orders WHERE id = 42", durationMs: 3.2)]
        ))

        #expect(result.success)
        let request = FakeIngestorProtocol.requests[0]
        #expect(request.url?.path == "/api/projects/demo/transactions")
        let spans = request.body?["spans"] as? [[String: Any]]
        #expect(spans?[0]["sql"] as? String == "SELECT * FROM orders WHERE id = ?")
    }

    @Test func filtersAndSendsLogsBySeverity() {
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            async: false,
            logsEnabled: true,
            minimumLogLevel: "warn"
        )
        let client = ErrorgapClient(cfg, session: session)

        #expect(client.notifyLog("noise", level: "debug").status == 204)
        #expect(client.notifyLog("timeout", level: "warning", source: "Checkout").success)
        #expect(FakeIngestorProtocol.requests.count == 1)
        #expect(FakeIngestorProtocol.requests[0].url?.path == "/api/projects/demo/logs")
        #expect(FakeIngestorProtocol.requests[0].body?["level"] as? String == "warn")
        #expect(FakeIngestorProtocol.requests[0].body?["source"] as? String == "Checkout")
    }

    @Test func recordsFailedJobsAsErrorsAndTransactions() {
        enum JobFailure: Error { case failed }
        let session = FakeIngestor.makeSession()
        let cfg = ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            async: false,
            apmEnabled: true
        )
        let client = ErrorgapClient(cfg, session: session)

        #expect(throws: JobFailure.self) {
            try client.trackJob("ReceiptJob", queue: "critical") { spans in
                spans.database("SELECT 7 WHERE id = 42", durationMs: 2.1)
                throw JobFailure.failed
            }
        }
        let paths = FakeIngestorProtocol.requests.compactMap { $0.url?.path }
        #expect(paths.contains("/api/projects/demo/notices"))
        #expect(paths.contains("/api/projects/demo/transactions"))
    }

    // Errors reported inside a transaction carry its id, so errorgap shows the
    // error an interaction raised on its trace and links the two.
    @Test func errorsInsideATransactionCarryItsId() async {
        let session = FakeIngestor.makeSession()
        let client = ErrorgapClient(ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            async: false,
            apmEnabled: true
        ), session: session)
        let transaction = ErrorgapTransaction(path: "/checkout", durationMs: 12)
        await withErrorgapTransaction(transaction.id) {
            await Task.yield()
            client.notify(NSError(domain: "checkout", code: 1, userInfo: [NSLocalizedDescriptionKey: "declined"]))
        }
        client.notify(NSError(domain: "checkout", code: 2))
        client.notifyTransaction(transaction)

        let requests = FakeIngestorProtocol.requests
        let inside = requests[0].body?["context"] as? [String: Any]
        let outside = requests[1].body?["context"] as? [String: Any]
        #expect(inside?["transaction_id"] as? String == transaction.id)
        #expect(outside?["transaction_id"] == nil)
        #expect(requests[2].body?["id"] as? String == transaction.id)
        #expect(transaction.id.count == 36)
        #expect(ErrorgapTransactionContext.current == nil)
    }

    @Test func aFailedJobsErrorCarriesTheJobsId() {
        let session = FakeIngestor.makeSession()
        let client = ErrorgapClient(ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "demo",
            async: false,
            apmEnabled: true
        ), session: session)
        var seen: String?
        _ = try? client.trackJob("ReceiptJob") { _ -> Int in
            seen = ErrorgapTransactionContext.current
            throw NSError(domain: "mail", code: 1)
        }

        let requests = FakeIngestorProtocol.requests
        let notice = requests.first { $0.url?.path.hasSuffix("/notices") == true }
        let transaction = requests.first { $0.url?.path.hasSuffix("/transactions") == true }
        #expect(seen != nil)
        #expect((notice?.body?["context"] as? [String: Any])?["transaction_id"] as? String == seen)
        #expect(transaction?.body?["id"] as? String == seen)
    }
}
