# Errorgap (Swift)

Swift notifier for [Errorgap](https://errorgap.com). Reports uncaught
`NSException` events and manual errors, records APM transactions and
background jobs, and forwards structured logs from iOS, macOS, watchOS, and
tvOS apps.

Raw runtime call stacks remain dSYM-compatible for later server-side
symbolication. Manually reported errors can also provide compile-time Swift
file and line frames so source renders immediately. Signal-handler-based crash
reporting (SIGABRT/SIGSEGV/...) and PLCrashReporter integration are deferred.

Requires Swift 5.9+, iOS 14+, macOS 11+, watchOS 7+, tvOS 14+.

## Install

Swift Package Manager. In `Package.swift`:

```swift
.package(url: "https://github.com/errorgaphq/errorgap-swift.git", from: "0.4.0")
```

…and add `"Errorgap"` to your target's dependencies.

Or in Xcode: File → Add Packages…

## Configure

In your app's launch path:

```swift
import Errorgap

Errorgap.initialize(ErrorgapConfiguration(
    endpoint: "https://errorgap.example.com",
    projectSlug: "your-project",
    apiKey: ProcessInfo.processInfo.environment["ERRORGAP_API_KEY"],
    environment: "production",
    release: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
))
```

`initialize` reads `ERRORGAP_ENDPOINT`, `ERRORGAP_PROJECT_SLUG`,
`ERRORGAP_PROJECT_ID`, and `ERRORGAP_API_KEY` from the environment when
fields are omitted. By default it installs
`NSSetUncaughtExceptionHandler`; pass `captureGlobals: false` to skip.

## Manual notification

```swift
do {
    try risky()
} catch {
    Errorgap.notify(error, options: NoticeOptions(context: ["component": "checkout"]))
    throw error
}
```

`notify` returns a `DeliveryResult` (`status`, `body`, `error`, `queued`).
The SDK never throws.

## Source-aware errors

Adopt `ErrorgapBacktraceProviding` on errors whose declaration or throw site
is known. The compile-time defaults capture the call site's file, line, and
function; Errorgap includes a bounded source excerpt from `rootDirectory`:

```swift
struct CheckoutFailure: LocalizedError, ErrorgapBacktraceProviding {
    let message: String
    let errorgapBacktrace: [ErrorgapBacktraceFrame]

    var errorDescription: String? { message }

    init(
        message: String,
        file: String = #filePath,
        line: Int = #line,
        function: String = #function
    ) {
        self.message = message
        self.errorgapBacktrace = [ErrorgapBacktraceFrame(
            file: file,
            line: line,
            function: function,
            inApp: true
        )]
    }
}
```

Use `inApp: false` for vendor frames. Raw frames from `NSError` /
`NSException.callStackSymbols` continue to be sent when source locations are
not available.

## APM

Enable APM with `apmEnabled: true` (or `ERRORGAP_APM_ENABLED=true`) and send
web transactions with database or outbound HTTP spans:

```swift
Errorgap.notifyTransaction(ErrorgapTransaction(
    method: "POST",
    path: "/orders/{id}",
    statusCode: 201,
    durationMs: 42.5,
    spans: [
        .database(
            "SELECT * FROM orders WHERE id = 42",
            durationMs: 3.2,
            file: #filePath,
            line: #line,
            function: #function
        ),
    ]
))
```

SQL literals are normalized for aggregation. Failed background jobs are
reported as both errors and APM job transactions:

```swift
try Errorgap.trackJob("ReceiptJob", queue: "critical") { spans in
    spans.database("SELECT 7 WHERE id = 42", durationMs: 2.1)
    try runReceiptJob()
}
```

### Link API calls to server traces

Trace a call to your API and errorgap links it to the server request that
answered it (when the server's errorgap SDK records the `x-errorgap-trace`
header — Rails, Laravel, Express, Django, Spring and the rest do):

```swift
let spans = ErrorgapSpanCollector()
let started = Date()
let (data, _) = try await spans.traceCall("GET /api/orders/7") { headers in
    var request = URLRequest(url: ordersURL)
    headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
    return try await URLSession.shared.data(for: request)
}
Errorgap.notifyTransaction(ErrorgapTransaction(
    path: "OrderScreen",
    durationMs: Date().timeIntervalSince(started) * 1000,
    spans: spans.snapshot()
))
```

`traceCall` records an `http` span carrying the trace id it sent; the app's
trace lists each traced call with a link to its server trace, and the server
trace shows how long the app waited. For manual timing use
`let call = spans.startCall(label)`, send `call.headers`, then `call.finish()`.

### Link errors to their transaction

Every `ErrorgapTransaction` has an `id`. Errors reported inside
`withErrorgapTransaction(id) { ... }` — and a failing `trackJob` — carry it as
`context.transaction_id`, so errorgap shows the error an interaction raised on
its trace:

```swift
let transaction = ErrorgapTransaction(path: "/checkout", durationMs: 0)
let started = Date()
await withErrorgapTransaction(transaction.id) {
    await submitOrder()   // errors reported here carry transaction.id
}
Errorgap.notifyTransaction(ErrorgapTransaction(
    id: transaction.id, path: "/checkout",
    durationMs: Date().timeIntervalSince(started) * 1_000
))
```

The id is a `@TaskLocal`: it flows into child tasks and never leaks into a
concurrent one.

## Logs

Enable forwarding with `logsEnabled: true` and configure `minimumLogLevel`
(`trace`, `debug`, `info`, `warn`, `error`, or `fatal`):

```swift
Errorgap.notifyLog(
    "payment gateway timeout",
    level: "warn",
    source: "CheckoutViewModel"
)

let logger = ErrorgapLogger(source: "CheckoutViewModel")
logger.error("checkout failed")
```

## Configuration reference

| Field | Default | Notes |
|---|---|---|
| `endpoint` | `ERRORGAP_ENDPOINT` or `http://127.0.0.1:3030` | |
| `projectSlug` | `ERRORGAP_PROJECT_SLUG` | **Required** |
| `projectId` | `ERRORGAP_PROJECT_ID` | |
| `apiKey` | `ERRORGAP_API_KEY` | Sent as `x-errorgap-project-key` |
| `environment` | `ERRORGAP_ENVIRONMENT` or `production` | |
| `release` | — | Sent in `context.release` |
| `rootDirectory` | Current working directory | Source lookup root |
| `inAppModules` | empty | Module names used to classify raw frames |
| `async` | `true` | Background `URLSession` tasks |
| `filterKeys` | `password, token, …` | Substring, case-insensitive |
| `timeout` | `5.0` | `URLSession` request timeout |
| `queueSize` | `100` | Maximum in-flight asynchronous deliveries |
| `apmEnabled` | `ERRORGAP_APM_ENABLED` or `false` | Send APM transactions |
| `apmSampleRate` | `ERRORGAP_APM_SAMPLE_RATE` or `1` | Clamped to `0...1` |
| `logsEnabled` | `ERRORGAP_LOGS_ENABLED` or `false` | Forward structured logs |
| `minimumLogLevel` | `ERRORGAP_MINIMUM_LOG_LEVEL` or `warn` | Client-side threshold |
| `deviceInfo` | empty | Override or supplement captured device metadata |

## Device metadata

The SDK auto-attaches `os_name`, `os_version`, `app_version`, `app_build`,
`bundle_id`, plus `device_model` / `device_name` on iOS/tvOS into the
notice's `environment` map.

Pass `deviceInfo` in the configuration to supplement or override captured
values, which is useful for custom device fields and deterministic tests.

## Graceful flush

```swift
Errorgap.flush(timeout: 5)
```

Wait for in-flight async deliveries before app suspension.

## Development

```sh
swift test
```

## License

MIT.
