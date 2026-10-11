import Foundation
import Testing
@testable import Errorgap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A fake Errorgap that answers the replay settings, session batches and
/// notices, and records every request.
final class ReplayServerProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [(url: String, headers: [String: String], body: [String: Any]?)] = []
    nonisolated(unsafe) static var enabled = true
    nonisolated(unsafe) static var sessionStatus = 201
    static let lock = NSLock()

    static func reset(enabled: Bool = true, sessionStatus: Int = 201) {
        lock.lock()
        requests = []
        self.enabled = enabled
        self.sessionStatus = sessionStatus
        lock.unlock()
    }

    static func sessionBatches() -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return requests.filter { $0.url.hasSuffix("/sessions") }.compactMap { $0.body }
    }

    static func urls() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.url }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!.absoluteString
        var headers: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] { headers[k.lowercased()] = v }
        let raw = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            return data
        }
        let body = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        Self.lock.lock()
        Self.requests.append((url, headers, body))
        let enabled = Self.enabled
        let sessionStatus = Self.sessionStatus
        Self.lock.unlock()

        let (status, payload): (Int, String)
        if url.contains("/sessions/config") {
            (status, payload) = (200, #"{"enabled":\#(enabled),"sample_rate":1}"#)
        } else if url.hasSuffix("/sessions") {
            (status, payload) = (sessionStatus, "")
        } else if url.hasSuffix("/notices") {
            (status, payload) = (201, #"{"group_id":"group-7"}"#)
        } else {
            (status, payload) = (503, "{}")
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct ReplayTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReplayServerProtocol.self]
        return URLSession(configuration: config)
    }

    private func configuration() -> ErrorgapConfiguration {
        ErrorgapConfiguration(
            endpoint: "https://errorgap.example.com",
            projectSlug: "app",
            apiKey: "egp_key",
            release: "2.3.0",
            async: false
        )
    }

    private func recorder() -> ErrorgapReplayRecorder {
        ErrorgapReplayRecorder(
            configuration: configuration(),
            session: session(),
            options: ErrorgapReplayOptions(appName: "Acme", os: "iOS 17.6", device: "Mobile", flushInterval: 3600)
        )
    }

    /// Waits for in-flight requests to land.
    private func settle(_ until: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if until() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func events() -> [[String: Any]] {
        ReplayServerProtocol.sessionBatches().flatMap { ($0["events"] as? [[String: Any]]) ?? [] }
    }

    private func labels() -> [String] {
        events().map { "\($0["type"] ?? ""):\($0["label"] ?? "")" }
    }

    @Test func recordsNothingWhileReplayIsOff() {
        ReplayServerProtocol.reset(enabled: false)
        let r = recorder()
        r.start()
        settle { ReplayServerProtocol.urls().count >= 1 }
        settle()
        r.screen("Checkout")
        r.paused()
        settle()
        #expect(ReplayServerProtocol.urls() == ["https://errorgap.example.com/api/projects/app/sessions/config?api_key=egp_key"])
        #expect(!r.recording)
    }

    @Test func recordsScreensFailedCallsAndErrorsLinkedToTheirGroup() {
        ReplayServerProtocol.reset()
        let r = recorder()
        r.start()
        settle { r.recording && !ReplayServerProtocol.sessionBatches().isEmpty }

        r.screen("Checkout")
        r.screen("Checkout")
        r.apiError(method: "post", url: URL(string: "https://api.acme.example/orders?token=secret"), status: 503)
        let done = r.errorStarted("TypeError: token is undefined")
        done("group-7")
        settle { self.labels().contains { $0.hasPrefix("error:") } }

        #expect(labels() == [
            "page_load:App started",
            "navigation:Opened Checkout",
            "api_error:POST https://api.acme.example/orders → 503",
            "error:TypeError: token is undefined",
        ])
        #expect((events().last?["group_id"] as? String) == "group-7")
        let lastSession = ReplayServerProtocol.sessionBatches().last?["session"] as? [String: Any]
        #expect((lastSession?["browser"] as? String) == "Acme 2.3.0")
        #expect((lastSession?["os"] as? String) == "iOS 17.6")
        #expect((lastSession?["outcome"] as? String) == "error")
    }

    @Test func aShortPauseKeepsTheSession() {
        ReplayServerProtocol.reset()
        let r = recorder()
        r.start()
        settle { r.recording }
        r.paused()
        r.resumed()
        r.screen("Home")
        r.flush(final: false)
        settle { self.labels().contains("navigation:Opened Home") }

        let ids = Set(ReplayServerProtocol.sessionBatches().compactMap { ($0["session"] as? [String: Any])?["id"] as? String })
        #expect(ids.count == 1)
        #expect(labels().contains("exit:App went to the background"))
        #expect(labels().contains("navigation:Returned to the app"))
    }

    @Test func stopsRecordingWhenTheServerRefusesTheSession() {
        ReplayServerProtocol.reset(sessionStatus: 204)
        let r = recorder()
        r.start()
        settle { !ReplayServerProtocol.sessionBatches().isEmpty }
        settle { !r.recording }
        #expect(!r.recording)
    }

    @Test func clientReportsErrorsToTheObserverWithTheirGroup() {
        ReplayServerProtocol.reset()
        let client = ErrorgapClient(configuration(), session: session())
        let groups = NSMutableArray()
        client.errorObserver = { label in
            #expect(label == "TestError: failed")
            return { groupId in groups.add(groupId ?? "none") }
        }
        struct TestError: Error, CustomStringConvertible { var description: String { "failed" } }
        _ = client.notify(TestError(), sync: true)
        #expect((groups as? [String]) == ["group-7"])
    }
}
