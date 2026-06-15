import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// URLProtocol that captures the most recent request and returns a stubbed
/// 201 response. Install on the URLSession used by the test client.
final class FakeIngestorProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [CapturedRequest] = []
    nonisolated(unsafe) static var responseStatus: Int = 201
    nonisolated(unsafe) static var responseBody: String = #"{"group_id":"g_1"}"#
    nonisolated(unsafe) static var requestLock = NSLock()

    struct CapturedRequest {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: [String: Any]?
        let raw: Data?
    }

    static func reset() {
        requestLock.lock()
        requests = []
        requestLock.unlock()
    }

    static func register() {
        URLProtocol.registerClass(FakeIngestorProtocol.self)
    }

    static func unregister() {
        URLProtocol.unregisterClass(FakeIngestorProtocol.self)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = request.httpBody
            ?? request.httpBodyStream.flatMap { Self.read($0) }
        var headers: [String: String] = [:]
        if let allHeaders = request.allHTTPHeaderFields {
            for (k, v) in allHeaders { headers[k.lowercased()] = v }
        }
        var decoded: [String: Any]? = nil
        if let body = body,
           let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            decoded = obj
        }
        let captured = CapturedRequest(
            url: request.url,
            method: request.httpMethod,
            headers: headers,
            body: decoded,
            raw: body
        )
        Self.requestLock.lock()
        Self.requests.append(captured)
        Self.requestLock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: Self.responseStatus,
            httpVersion: "HTTP/1.1",
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseBody.data(using: .utf8)!)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) } else { break }
        }
        return data
    }
}

enum FakeIngestor {
    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeIngestorProtocol.self]
        return URLSession(configuration: config)
    }
}
