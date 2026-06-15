# Errorgap (Swift)

Swift notifier for [Errorgap](https://errorgap.com). Reports uncaught
`NSException` events and manual errors from iOS, macOS, watchOS, and tvOS
apps.

This v1 ships errors only with raw (unsymbolicated) call stacks — the
server symbolicates using uploaded dSYM bundles. Signal-handler-based
crash reporting (SIGABRT/SIGSEGV/...) and PLCrashReporter integration are
deferred.

Requires Swift 5.9+, iOS 14+, macOS 11+, watchOS 7+, tvOS 14+.

## Install

Swift Package Manager. In `Package.swift`:

```swift
.package(url: "https://gitlab.jgrubbs.net/jGRUBBS/errorgap-swift.git", from: "0.1.0")
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

## Configuration reference

| Field | Default | Notes |
|---|---|---|
| `endpoint` | `ERRORGAP_ENDPOINT` or `http://127.0.0.1:3030` | |
| `projectSlug` | `ERRORGAP_PROJECT_SLUG` | **Required** |
| `projectId` | `ERRORGAP_PROJECT_ID` | |
| `apiKey` | `ERRORGAP_API_KEY` | Sent as `x-errorgap-project-key` |
| `environment` | `ERRORGAP_ENVIRONMENT` or `production` | |
| `release` | — | Sent in `context.release` |
| `async` | `true` | Background `URLSession` tasks |
| `filterKeys` | `password, token, …` | Substring, case-insensitive |
| `timeout` | `5.0` | `URLSession` request timeout |

## Device metadata

The SDK auto-attaches `os_name`, `os_version`, `app_version`, `app_build`,
`bundle_id`, plus `device_model` / `device_name` on iOS/tvOS into the
notice's `environment` map.

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
