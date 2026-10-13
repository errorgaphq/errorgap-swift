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

    /// Session replay records each reported error, linked to its group: told
    /// the error's label, it returns what to call with the group id.
    var errorObserver: ((String) -> (String?) -> Void)?

    /// The URLSession the SDK sends with (session replay shares it).
    var urlSession: URLSession { session }

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

        if configuration.ignoredEnvironment {
            return DeliveryResult(status: 202, body: "ignored environment", error: nil, queued: false)
        }
        guard let notice = prepare(error, options: options) else {
            return DeliveryResult(status: 202, body: "dropped by beforeNotify", error: nil, queued: false)
        }
        var observed: ((String?) -> Void)?
        if let observer = errorObserver {
            let first = (notice["errors"] as? [[String: Any]])?.first
            let type = first?["type"] as? String ?? "Error"
            let message = first?["message"] as? String ?? String(describing: error)
            observed = observer("\(type): \(message)")
        }
        return submit(resource: "notices", payload: notice, sync: sync) { result in
            observed?(groupId(of: result))
        }
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

    /// The notice for `error` after `beforeNotify`, or nil when the hook
    /// dropped it.
    private func prepare(_ error: Error, options: NoticeOptions) -> [String: Any]? {
        let notice = Notice.build(error: error, config: configuration, options: withTransaction(options))
        guard let hook = configuration.beforeNotify else { return notice }
        return hook(notice)
    }

    // MARK: - Crashes

    /// This launch's signal file: not to be read back while it is in use.
    private var activeSignalFile: String?

    /// Start recording fatal signals (memory faults, `fatalError`, a
    /// force-unwrapped `nil`) into `crashDirectory`, to be reported on the
    /// next launch. Does nothing without `crashDirectory`.
    func captureSignals() {
        #if canImport(Darwin)
        guard let folder = crashFolder else { return }
        activeSignalFile = SignalCrashes.install(folder: folder)
        #endif
    }

    private var crashFolder: URL? {
        configuration.crashDirectory.map { URL(fileURLWithPath: $0).appendingPathComponent("errorgap-crashes") }
    }

    /// Report an uncaught exception. The notice is written to
    /// `crashDirectory` first and removed once the server has it, so if the
    /// app is gone before the request finishes the next launch sends it.
    @discardableResult
    public func notifyCrash(_ error: Error, options: NoticeOptions = NoticeOptions()) -> DeliveryResult {
        guard (try? configuration.validate()) != nil, !configuration.ignoredEnvironment else {
            return DeliveryResult(status: 202, body: nil, error: nil, queued: false)
        }
        guard let notice = prepare(error, options: options),
              let request = buildRequest(resource: "notices", payload: notice)
        else {
            return DeliveryResult(status: 202, body: "dropped by beforeNotify", error: nil, queued: false)
        }
        var stored: URL?
        if let folder = crashFolder, let body = request.httpBody {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("crash-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString).json")
            if (try? body.write(to: file, options: .atomic)) != nil { stored = file }
        }
        let result = deliverSync(request)
        if let stored, Self.delivered(result) { try? FileManager.default.removeItem(at: stored) }
        return result
    }

    /// Send the crashes the previous launch could not deliver. Returns how
    /// many were sent.
    @discardableResult
    public func sendStoredCrashes() -> Int {
        guard let folder = crashFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return 0 }
        var sent = 0
        #if canImport(Darwin)
        // Fatal signals: the handler could only save the stack; build the
        // notice now. An empty file is a launch that ended normally.
        for file in files where file.lastPathComponent.hasPrefix(SignalCrashes.filePrefix) {
            if file.lastPathComponent == activeSignalFile { continue }
            defer { try? FileManager.default.removeItem(at: file) }
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let crash = SignalCrashes.parse(text)
            else { continue }
            let name = SignalCrashes.name(crash.signal)
            let error = NSError(domain: "io.errorgap.signal", code: Int(crash.signal), userInfo: [
                "callStackSymbols": crash.symbols,
                NSLocalizedDescriptionKey: "The app was ended by \(name)",
                Notice.typeKey: name,
            ])
            let result = notify(error, options: NoticeOptions(context: [
                "source": "signal",
                "signal": name,
                "reported_on": "next launch",
            ]), sync: true)
            if result.success { sent += 1 }
        }
        #endif
        // Oldest first, and never more than a crash loop's worth.
        for file in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).suffix(10) {
            guard let body = try? Data(contentsOf: file), !body.isEmpty,
                  var request = buildRequest(resource: "notices", payload: [:])
            else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            request.httpBody = body
            guard Self.delivered(deliverSync(request)) else { break }
            try? FileManager.default.removeItem(at: file)
            sent += 1
        }
        return sent
    }

    /// The server has it, or refused it for good: either way do not keep it.
    private static func delivered(_ result: DeliveryResult) -> Bool {
        guard let status = result.status else { return false }
        return status < 500 && status != 429
    }

    // MARK: - Rate limiting

    private var pausedUntil = Date.distantPast

    /// True while delivery is paused at the server's request (a 429 or 503
    /// with `Retry-After`).
    public var paused: Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return Date() < pausedUntil
    }

    private func pauseIfLimited(_ response: URLResponse?) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 429 || http.statusCode == 503 else { return }
        let header = http.value(forHTTPHeaderField: "Retry-After") ?? ""
        let seconds = min(max(Double(header.trimmingCharacters(in: .whitespaces)) ?? 60, 1), 300)
        pendingLock.lock()
        pausedUntil = Date().addingTimeInterval(seconds)
        pendingLock.unlock()
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
        sync: Bool,
        onDelivered: ((DeliveryResult) -> Void)? = nil
    ) -> DeliveryResult {
        if configuration.ignoredEnvironment {
            return DeliveryResult(status: 204, body: nil, error: nil, queued: false)
        }
        guard let request = buildRequest(resource: resource, payload: payload) else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.encoding, queued: false)
        }
        if sync || !configuration.async {
            let result = deliverSync(request)
            onDelivered?(result)
            return result
        }
        guard deliverAsync(request, onDelivered: onDelivered) else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.queueFull, queued: false)
        }
        return DeliveryResult(status: 202, body: nil, error: nil, queued: true)
    }

    private func deliverSync(_ request: URLRequest) -> DeliveryResult {
        if paused {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.rateLimited, queued: false)
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result = DeliveryResult(status: nil, body: nil, error: nil, queued: false)
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.pauseIfLimited(response)
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

    private func deliverAsync(_ request: URLRequest, onDelivered: ((DeliveryResult) -> Void)? = nil) -> Bool {
        if paused {
            onDelivered?(DeliveryResult(status: nil, body: nil, error: ErrorgapError.rateLimited, queued: false))
            return true
        }
        let id = UUID()
        pendingLock.lock()
        guard pendingTasks.count < configuration.queueSize else {
            pendingLock.unlock()
            return false
        }
        pendingTasks.insert(id)
        pendingLock.unlock()

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            self?.pauseIfLimited(response)
            if let onDelivered {
                let body = data.flatMap { String(data: $0, encoding: .utf8) }
                onDelivered(DeliveryResult(
                    status: (response as? HTTPURLResponse)?.statusCode,
                    body: body,
                    error: error,
                    queued: false
                ))
            }
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

/// The error group the notice response names, for session replay.
private func groupId(of result: DeliveryResult) -> String? {
    guard let body = result.body, let data = body.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["group_id"] as? String
}
