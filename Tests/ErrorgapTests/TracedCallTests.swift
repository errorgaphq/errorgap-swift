import Foundation
import Testing
@testable import Errorgap

struct TracedCallTests {
    private struct Offline: Error {}

    @Test func traceCallRecordsTheTraceIdItSends() async throws {
        let spans = ErrorgapSpanCollector()
        var sent: [String: String] = [:]
        let result = await spans.traceCall("GET /api/orders/7") { headers -> String in
            sent = headers
            return "ok"
        }
        #expect(result == "ok")
        let span = try #require(spans.snapshot().first)
        #expect(span.kind == "http")
        #expect(span.function == "GET /api/orders/7")
        let traceId = try #require(span.traceId)
        #expect(UUID(uuidString: traceId) != nil)
        #expect(traceId == traceId.lowercased())
        #expect(sent == ["x-errorgap-trace": traceId])
        #expect(span.payload()["trace_id"] as? String == traceId)
        #expect(span.payload()["fn_name"] as? String == "GET /api/orders/7")
    }

    @Test func traceCallRecordsTheSpanWhenItThrowsAndFinishIsIdempotent() async {
        let spans = ErrorgapSpanCollector()
        await #expect(throws: Offline.self) {
            try await spans.traceCall("POST /api/pay") { _ in throw Offline() }
        }
        let call = spans.startCall("GET /api/menu")
        call.finish()
        call.finish()
        #expect(spans.snapshot().map(\.function) == ["POST /api/pay", "GET /api/menu"])
    }
}
