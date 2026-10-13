import Foundation
import Testing
@testable import Errorgap

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A URLProtocol of this suite's own (the shared fake ingestor's state is
/// global, and suites run in parallel) that answers with `status`.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var status = 201
    nonisolated(unsafe) static var bodies: [String] = []
    nonisolated(unsafe) static let lock = NSLock()

    static func reset(status: Int = 201) {
        lock.lock()
        self.status = status
        bodies = []
        lock.unlock()
    }

    static var received: [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read > 0 { data.append(buffer, count: read) } else { break }
            }
            stream.close()
        }
        Self.lock.lock()
        Self.bodies.append(String(data: data, encoding: .utf8) ?? "")
        let status = Self.status
        Self.lock.unlock()

        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized)
struct HardeningTests {
    private func client(
        environment: String = "production",
        ignoreEnvironments: [String] = [],
        beforeNotify: (([String: Any]) -> [String: Any]?)? = nil,
        crashDirectory: String? = nil
    ) -> ErrorgapClient {
        ErrorgapClient(
            ErrorgapConfiguration(
                endpoint: "https://errorgap.example.com",
                projectSlug: "demo",
                environment: environment,
                async: false,
                ignoreEnvironments: ignoreEnvironments,
                beforeNotify: beforeNotify,
                crashDirectory: crashDirectory
            ),
            session: StubProtocol.session()
        )
    }

    private func error(_ message: String) -> NSError {
        NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
    }

    @Test func a429PausesSending() {
        StubProtocol.reset(status: 429)
        let sdk = client()
        #expect(sdk.notify(error("one")).status == 429)
        #expect(sdk.paused)
        #expect(sdk.notify(error("two")).error as? ErrorgapError == .rateLimited)
        #expect(StubProtocol.received.count == 1)
    }

    @Test func beforeNotifyCanDropOrChangeANotice() {
        StubProtocol.reset()
        #expect(client(beforeNotify: { _ in nil }).notify(error("no")).body == "dropped by beforeNotify")
        let changed = client(beforeNotify: { notice in
            var notice = notice
            notice["params"] = ["team": "billing"]
            return notice
        }).notify(error("yes"))
        #expect(changed.success)
        #expect(StubProtocol.received.count == 1)
        #expect(StubProtocol.received[0].contains("billing"))
    }

    @Test func nothingIsSentInAnIgnoredEnvironment() {
        StubProtocol.reset()
        let result = client(environment: "test", ignoreEnvironments: ["test"]).notify(error("x"))
        #expect(result.body == "ignored environment")
        #expect(StubProtocol.received.isEmpty)
    }

    @Test func sensitiveKeysAreMaskedInsideArraysAndInTheSession() {
        let filtered = Filter.params(
            ["users": [["password": "p", "name": "Ada"]], "long": String(repeating: "x", count: 10_000)],
            filterKeys: ["password"]
        )
        let user = (filtered["users"] as? [[String: Any]])?.first
        #expect(user?["password"] as? String == "[FILTERED]")
        #expect(user?["name"] as? String == "Ada")
        #expect((filtered["long"] as? String)?.hasSuffix("[TRUNCATED]") == true)

        let notice = Notice.build(
            error: error("x"),
            config: ErrorgapConfiguration(projectSlug: "demo"),
            options: NoticeOptions(session: ["auth_token": "t"])
        )
        #expect((notice["session"] as? [String: Any])?["auth_token"] as? String == "[FILTERED]")
    }

    @Test func aCrashIsKeptUntilTheServerHasIt() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("errorgap-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("errorgap-crashes")
        func stored() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0 }

        // The server fails: the crash stays on disk.
        StubProtocol.reset(status: 500)
        client(crashDirectory: directory.path).notifyCrash(error("crashed"))
        #expect(stored() == 1)

        // Next launch, the server is back.
        StubProtocol.reset()
        #expect(client(crashDirectory: directory.path).sendStoredCrashes() == 1)
        #expect(StubProtocol.received.first?.contains("crashed") == true)
        #expect(stored() == 0)

        // A crash that is delivered straight away is not kept.
        client(crashDirectory: directory.path).notifyCrash(error("delivered"))
        #expect(stored() == 0)
    }
}
