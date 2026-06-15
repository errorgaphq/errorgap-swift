import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DeliveryResult {
    public let status: Int?
    public let body: String?
    public let error: Error?
    public let queued: Bool

    public var success: Bool {
        error == nil && (status.map { (200..<300).contains($0) } ?? false)
    }
}

public final class ErrorgapClient {
    private let configuration: ErrorgapConfiguration
    private let session: URLSession
    private let queue: DispatchQueue
    private let workQueue = DispatchQueue(label: "io.errorgap.delivery", qos: .utility)
    private var pendingTasks: Set<UUID> = []
    private let pendingLock = NSLock()

    public init(_ configuration: ErrorgapConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        self.queue = DispatchQueue(label: "io.errorgap.client.serial")
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = configuration.timeout
            self.session = URLSession(configuration: config)
        }
    }

    @discardableResult
    public func notify(
        _ error: Error,
        options: NoticeOptions = NoticeOptions(),
        sync: Bool = false
    ) -> DeliveryResult {
        do {
            try configuration.validate()
        } catch {
            return DeliveryResult(status: nil, body: nil, error: error, queued: false)
        }

        let notice = Notice.build(error: error, config: configuration, options: options)

        if sync || !configuration.async {
            return deliverSync(notice)
        }

        deliverAsync(notice)
        return DeliveryResult(status: 202, body: nil, error: nil, queued: true)
    }

    public func flush(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            pendingLock.lock()
            let empty = pendingTasks.isEmpty
            pendingLock.unlock()
            if empty || Date() >= deadline { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    // MARK: - Delivery

    private func deliverSync(_ notice: [String: Any]) -> DeliveryResult {
        guard let request = buildRequest(notice: notice) else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.encoding, queued: false)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result = DeliveryResult(status: nil, body: nil, error: nil, queued: false)
        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                result = DeliveryResult(status: nil, body: nil, error: error, queued: false)
            } else if let http = response as? HTTPURLResponse {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }
                result = DeliveryResult(status: http.statusCode, body: body, error: nil, queued: false)
            }
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + configuration.timeout + 1)
        return result
    }

    private func deliverAsync(_ notice: [String: Any]) {
        guard let request = buildRequest(notice: notice) else { return }
        let id = UUID()
        pendingLock.lock()
        pendingTasks.insert(id)
        pendingLock.unlock()

        let task = session.dataTask(with: request) { [weak self] _, _, _ in
            self?.pendingLock.lock()
            self?.pendingTasks.remove(id)
            self?.pendingLock.unlock()
        }
        task.resume()
    }

    private func buildRequest(notice: [String: Any]) -> URLRequest? {
        guard let body = JSON.encode(notice) else { return nil }
        let trimmed = configuration.endpoint.hasSuffix("/")
            ? String(configuration.endpoint.dropLast())
            : configuration.endpoint
        guard
            let slug = configuration.projectSlug,
            let url = URL(string: "\(trimmed)/api/projects/\(slug)/notices")
        else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("errorgap-swift/\(ErrorgapVersion.current)", forHTTPHeaderField: "user-agent")
        if let key = configuration.apiKey, !key.isEmpty {
            request.setValue(key, forHTTPHeaderField: "x-errorgap-project-key")
        }
        return request
    }
}
