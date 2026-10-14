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
    nonisolated(unsafe) static var settings: String?
    nonisolated(unsafe) static let lock = NSLock()

    static func reset(status: Int = 201) {
        lock.lock()
        self.status = status
        bodies = []
        settings = nil
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
        // The settings poll: answered from `settings` (404 when unset), not recorded.
        if request.httpMethod == "GET" {
            Self.lock.lock()
            let settings = Self.settings
            Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: settings == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let settings { client?.urlProtocol(self, didLoad: Data(settings.utf8)) }
            client?.urlProtocolDidFinishLoading(self)
            return
        }
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

    @Test func aKindSwitchedOffInErrorgapIsNotSent() {
        StubProtocol.reset()
        StubProtocol.lock.lock()
        StubProtocol.settings = #"{"errors_enabled":false,"apm_enabled":true,"poll_interval_seconds":600}"#
        StubProtocol.lock.unlock()
        let sdk = client()
        #expect(sdk.refreshRemoteSettings())
        #expect(sdk.notify(error("x")).body == "switched off for this project")
        #expect(StubProtocol.received.isEmpty)
        #expect(sdk.remoteEnabled("transactions"))

        // Unreadable settings keep what was known; with none, everything is on.
        StubProtocol.reset()
        #expect(!client().refreshRemoteSettings())
        #expect(client().notify(error("y")).success)
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

// In the same (serialized) suite: these share the stub's state.
#if canImport(Darwin)
extension HardeningTests {
    @Test func aStoredSignalCrashBecomesANoticeOnTheNextLaunch() throws {
        StubProtocol.reset()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("errorgap-\(UUID().uuidString)")
        let folder = directory.appendingPathComponent("errorgap-crashes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // What the signal handler leaves behind, and an empty file from a launch that ended normally.
        try """
        signal 11
        0   Errorgap                            0x0000000100a1b2c4 handleFatalSignal + 80
        1   libsystem_platform.dylib            0x000000018e3d2a24 _sigtramp + 56
        2   MyApp                               0x0000000100003f20 $s5MyApp9loadOrderyyF + 32
        3   MyApp                               0x0000000100003e10 main + 12
        """.write(to: folder.appendingPathComponent("signal-previous.txt"), atomically: true, encoding: .utf8)
        try "".write(to: folder.appendingPathComponent("signal-clean-exit.txt"), atomically: true, encoding: .utf8)

        let client = ErrorgapClient(
            ErrorgapConfiguration(endpoint: "https://errorgap.example.com", projectSlug: "demo", async: false, crashDirectory: directory.path),
            session: StubProtocol.session()
        )
        #expect(client.sendStoredCrashes() == 1)

        let body = try #require(StubProtocol.received.first)
        let notice = try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        let error = try #require((notice["errors"] as? [[String: Any]])?.first)
        #expect(error["type"] as? String == "SIGSEGV")
        #expect((notice["context"] as? [String: Any])?["source"] as? String == "signal")
        let frames = try #require(error["backtrace"] as? [[String: Any]])
        #expect(frames.count == 2) // the handler and the trampoline are left out
        #expect(body.contains("MyApp.loadOrder()"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty)
    }

    @Test func parsingIgnoresAFileWithNoSignal() {
        #expect(SignalCrashes.parse("") == nil)
        #expect(SignalCrashes.parse("garbage") == nil)
        #expect(SignalCrashes.parse("signal 6\n")?.signal == 6)
    }
}
#endif
