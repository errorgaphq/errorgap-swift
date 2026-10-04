import Foundation

public struct ErrorgapSpan {
    public let kind: String
    public let sql: String?
    public let file: String?
    public let line: Int?
    public let function: String?
    public let durationMs: Double
    /// For a traced `http` call: the id sent in its `x-errorgap-trace` header.
    /// The server request that recorded the header links to it.
    public let traceId: String?

    public init(
        kind: String,
        sql: String? = nil,
        file: String? = nil,
        line: Int? = nil,
        function: String? = nil,
        durationMs: Double,
        traceId: String? = nil
    ) {
        self.kind = kind
        self.sql = sql
        self.file = file
        self.line = line
        self.function = function
        self.durationMs = durationMs
        self.traceId = traceId
    }

    public static func database(
        _ sql: String,
        durationMs: Double,
        file: String? = nil,
        line: Int? = nil,
        function: String? = nil
    ) -> ErrorgapSpan {
        ErrorgapSpan(
            kind: "db",
            sql: normalizeSQL(sql),
            file: file,
            line: line,
            function: function,
            durationMs: durationMs
        )
    }

    public static func external(
        durationMs: Double,
        file: String? = nil,
        line: Int? = nil,
        function: String? = nil
    ) -> ErrorgapSpan {
        ErrorgapSpan(
            kind: "http",
            file: file,
            line: line,
            function: function,
            durationMs: durationMs
        )
    }

    func payload() -> [String: Any] {
        var value: [String: Any] = ["kind": kind, "duration_ms": durationMs]
        if let sql { value["sql"] = sql }
        if let file { value["file"] = file }
        if let line { value["line"] = line }
        if let function { value["fn_name"] = function }
        if let traceId { value["trace_id"] = traceId }
        return value
    }
}

public struct ErrorgapTransaction {
    /// Links errors raised during this transaction to it; see `withErrorgapTransaction`.
    public let id: String
    public let kind: String
    public let method: String?
    public let path: String?
    public let pathRaw: String?
    public let statusCode: Int?
    public let durationMs: Double
    public let environment: String?
    public let occurredAt: String
    public let spans: [ErrorgapSpan]
    public let jobClass: String?
    public let queue: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        kind: String = "web",
        method: String? = nil,
        path: String? = nil,
        pathRaw: String? = nil,
        statusCode: Int? = nil,
        durationMs: Double,
        environment: String? = nil,
        occurredAt: String? = nil,
        spans: [ErrorgapSpan] = [],
        jobClass: String? = nil,
        queue: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.method = method
        self.path = path
        self.pathRaw = pathRaw
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.environment = environment
        self.occurredAt = occurredAt ?? errorgapTimestamp()
        self.spans = spans
        self.jobClass = jobClass
        self.queue = queue
    }

    func payload(configuration: ErrorgapConfiguration) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "kind": kind,
            "duration_ms": durationMs,
            "environment": environment ?? configuration.environment,
            "occurred_at": occurredAt,
            "spans": spans.map { $0.payload() },
        ]
        if let method { value["method"] = method }
        if let path { value["path"] = path }
        if let pathRaw { value["path_raw"] = pathRaw }
        if let statusCode { value["status_code"] = statusCode }
        if let jobClass { value["job_class"] = jobClass }
        if let queue { value["queue"] = queue }
        return value
    }
}

public final class ErrorgapSpanCollector {
    private let lock = NSLock()
    private var spans: [ErrorgapSpan] = []

    public init() {}

    public func add(_ span: ErrorgapSpan) {
        lock.lock()
        spans.append(span)
        lock.unlock()
    }

    public func database(
        _ sql: String,
        durationMs: Double,
        file: String? = nil,
        line: Int? = nil,
        function: String? = nil
    ) {
        add(.database(sql, durationMs: durationMs, file: file, line: line, function: function))
    }

    public func external(
        durationMs: Double,
        file: String? = nil,
        line: Int? = nil,
        function: String? = nil
    ) {
        add(.external(durationMs: durationMs, file: file, line: line, function: function))
    }

    /// Start a traced API call. Send `call.headers` with the request and call
    /// `call.finish()` when the response arrives: the `http` span records the
    /// trace id, and a server SDK that records the header links the server
    /// request to it.
    public func startCall(_ label: String) -> ErrorgapTracedCall {
        ErrorgapTracedCall(label: label, collector: self)
    }

    /// Time a traced API call: `operation` gets the headers to send, and its
    /// result is returned. The span is recorded even if it throws.
    ///
    ///     let (data, _) = try await spans.traceCall("GET /api/orders/7") { headers in
    ///         var request = URLRequest(url: url)
    ///         headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    ///         return try await URLSession.shared.data(for: request)
    ///     }
    public func traceCall<T>(
        _ label: String,
        _ operation: ([String: String]) async throws -> T
    ) async rethrows -> T {
        let call = startCall(label)
        defer { call.finish() }
        return try await operation(call.headers)
    }

    /// The spans recorded so far, for a transaction you deliver yourself.
    public func snapshot() -> [ErrorgapSpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans
    }
}

/// The header that links an API call to the server request answering it.
public let errorgapTraceHeader = "x-errorgap-trace"

/// A traced outbound call in flight; see `ErrorgapSpanCollector.startCall`.
public final class ErrorgapTracedCall {
    /// The id sent with the call.
    public let traceId: String
    /// Headers to add to the request: `["x-errorgap-trace": traceId]`.
    public let headers: [String: String]
    private let label: String
    private let started = Date()
    private let lock = NSLock()
    private var finished = false
    private weak var collector: ErrorgapSpanCollector?

    init(label: String, collector: ErrorgapSpanCollector) {
        let traceId = UUID().uuidString.lowercased()
        self.traceId = traceId
        self.headers = [errorgapTraceHeader: traceId]
        self.label = label
        self.collector = collector
    }

    /// Record the call's span, timed from `startCall`. Idempotent.
    public func finish() {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        collector?.add(ErrorgapSpan(
            kind: "http",
            function: label,
            durationMs: Date().timeIntervalSince(started) * 1000,
            traceId: traceId
        ))
    }
}

public func normalizeSQL(_ sql: String) -> String {
    sql
        .replacingOccurrences(of: "'(?:''|[^'])*'", with: "?", options: .regularExpression)
        .replacingOccurrences(of: "\\b\\d+(?:\\.\\d+)?\\b", with: "?", options: .regularExpression)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func errorgapTimestamp() -> String {
    ISO8601DateFormatter.errorgapFormatter.string(from: Date())
}
