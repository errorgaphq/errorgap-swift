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
    private var pendingTasks: Set<UUID> = []
    private let pendingLock = NSLock()

    public init(_ configuration: ErrorgapConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
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

        let notice = Notice.build(error: error, config: configuration, options: withTransaction(options))
        return submit(resource: "notices", payload: notice, sync: sync)
    }

    @discardableResult
    public func notifyTransaction(
        _ transaction: ErrorgapTransaction,
        sync: Bool = false
    ) -> DeliveryResult {
        do {
            try configuration.validate()
        } catch {
            return DeliveryResult(status: nil, body: nil, error: error, queued: false)
        }
        guard configuration.apmEnabled else {
            return DeliveryResult(status: 204, body: nil, error: nil, queued: false)
        }
        let rate = configuration.apmSampleRate
        guard rate > 0, rate >= 1 || Double.random(in: 0..<1) < rate else {
            return DeliveryResult(status: 204, body: nil, error: nil, queued: false)
        }
        return submit(
            resource: "transactions",
            payload: transaction.payload(configuration: configuration),
            sync: sync
        )
    }

    @discardableResult
    public func notifyLog(
        _ message: String,
        level: String = "info",
        source: String? = nil,
        sync: Bool = false
    ) -> DeliveryResult {
        do {
            try configuration.validate()
        } catch {
            return DeliveryResult(status: nil, body: nil, error: error, queued: false)
        }
        let normalizedLevel = normalizeLogLevel(level)
        guard configuration.logsEnabled,
              logLevelRank(normalizedLevel) >= logLevelRank(normalizeLogLevel(configuration.minimumLogLevel))
        else {
            return DeliveryResult(status: 204, body: nil, error: nil, queued: false)
        }
        var payload: [String: Any] = [
            "message": message,
            "level": normalizedLevel,
            "environment": configuration.environment,
            "occurred_at": errorgapTimestamp(),
        ]
        if let source, !source.isEmpty { payload["source"] = source }
        return submit(resource: "logs", payload: payload, sync: sync)
    }

    public func trackJob<T>(
        _ jobClass: String,
        queue: String = "default",
        operation: (ErrorgapSpanCollector) throws -> T
    ) rethrows -> T {
        let transactionId = UUID().uuidString.lowercased()
        let startedAt = errorgapTimestamp()
        let started = Date()
        let collector = ErrorgapSpanCollector()
        do {
            let value = try withErrorgapTransaction(transactionId) { try operation(collector) }
            _ = notifyTransaction(ErrorgapTransaction(
                id: transactionId,
                kind: "job",
                statusCode: 200,
                durationMs: Date().timeIntervalSince(started) * 1_000,
                occurredAt: startedAt,
                spans: collector.snapshot(),
                jobClass: jobClass,
                queue: queue
            ))
            return value
        } catch {
            _ = notify(error, options: NoticeOptions(
                context: [
                    "source": "errorgap-swift job",
                    "component": "swift.job",
                    "action": jobClass,
                    "transaction_id": transactionId,
                ],
                environment: ["queue": queue]
            ))
            _ = notifyTransaction(ErrorgapTransaction(
                id: transactionId,
                kind: "job",
                statusCode: 500,
                durationMs: Date().timeIntervalSince(started) * 1_000,
                occurredAt: startedAt,
                spans: collector.snapshot(),
                jobClass: jobClass,
                queue: queue
            ))
            throw error
        }
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

    private func submit(
        resource: String,
        payload: [String: Any],
        sync: Bool
    ) -> DeliveryResult {
        guard let request = buildRequest(resource: resource, payload: payload) else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.encoding, queued: false)
        }
        if sync || !configuration.async {
            return deliverSync(request)
        }
        guard deliverAsync(request) else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.queueFull, queued: false)
        }
        return DeliveryResult(status: 202, body: nil, error: nil, queued: true)
    }

    private func deliverSync(_ request: URLRequest) -> DeliveryResult {
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

    private func deliverAsync(_ request: URLRequest) -> Bool {
        let id = UUID()
        pendingLock.lock()
        guard pendingTasks.count < configuration.queueSize else {
            pendingLock.unlock()
            return false
        }
        pendingTasks.insert(id)
        pendingLock.unlock()

        let task = session.dataTask(with: request) { [weak self] _, _, _ in
            self?.pendingLock.lock()
            self?.pendingTasks.remove(id)
            self?.pendingLock.unlock()
        }
        task.resume()
        return true
    }

    private func buildRequest(resource: String, payload: [String: Any]) -> URLRequest? {
        guard let body = JSON.encode(payload) else { return nil }
        let trimmed = configuration.endpoint.hasSuffix("/")
            ? String(configuration.endpoint.dropLast())
            : configuration.endpoint
        guard
            let slug = configuration.projectSlug,
            let url = URL(string: "\(trimmed)/api/projects/\(slug)/\(resource)")
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

    private func normalizeLogLevel(_ level: String) -> String {
        switch level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "warning", "warn": return "warn"
        case "err", "severe": return "error"
        case "fine", "finer", "finest": return "debug"
        case "trace", "debug", "info", "error", "fatal":
            return level.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        default: return "info"
        }
    }

    private func logLevelRank(_ level: String) -> Int {
        switch level {
        case "trace": return 0
        case "debug": return 10
        case "info": return 20
        case "warn": return 30
        case "error": return 40
        case "fatal": return 50
        default: return 20
        }
    }
}

/// The transaction this error was raised in (`ErrorgapTransactionContext`),
/// unless the caller set one, so errorgap links the two.
private func withTransaction(_ options: NoticeOptions) -> NoticeOptions {
    guard let id = ErrorgapTransactionContext.current,
          options.context?["transaction_id"] == nil
    else { return options }
    var resolved = options
    var context = options.context ?? [:]
    context["transaction_id"] = id
    resolved.context = context
    return resolved
}
