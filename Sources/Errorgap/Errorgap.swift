import Foundation

// Module-level state read from the C uncaught-exception handler trampoline.
// nonisolated(unsafe) lets us touch these from a C callback without
// Sendable/MainActor friction; access from Swift is gated through stateLock.
nonisolated(unsafe) private var sharedClient: ErrorgapClient?
nonisolated(unsafe) private var sharedReplay: ErrorgapReplayRecorder?
nonisolated(unsafe) private var lifecycleObservers: [NSObjectProtocol] = []
private let stateLock = NSLock()

/// UIKit's app lifecycle notifications, by name, so the SDK needn't import UIKit.
private let didEnterBackground = Notification.Name("UIApplicationDidEnterBackgroundNotification")
private let willEnterForeground = Notification.Name("UIApplicationWillEnterForegroundNotification")

#if canImport(ObjectiveC)
nonisolated(unsafe) private var previousHandler: (@convention(c) (NSException) -> Void)?
private let uncaughtTrampoline: @convention(c) (NSException) -> Void = { exception in
    let userInfo: [String: Any] = [
        "callStackSymbols": exception.callStackSymbols,
        NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue,
    ]
    let nsError = NSError(domain: "io.errorgap.uncaught", code: 0, userInfo: userInfo)
    // Stored first, removed once delivered: see ErrorgapClient.notifyCrash.
    _ = sharedClient?.notifyCrash(nsError, options: NoticeOptions(context: [
        "source": "NSSetUncaughtExceptionHandler",
        "exception_name": exception.name.rawValue,
    ]))
    if let prev = previousHandler {
        prev(exception)
    }
}
#endif

public enum Errorgap {
    /// - Parameters:
    ///   - replay: Session replay (a timeline of the app session, no
    ///     screenshots). Defaults to on in iOS and tvOS apps; it records only
    ///     what the project's replay settings allow (Settings → Session replay).
    ///     `false` turns it off, `true` records on other platforms too.
    public static func initialize(
        _ configuration: ErrorgapConfiguration,
        captureGlobals: Bool = true,
        replay: Bool? = nil,
        replayOptions: ErrorgapReplayOptions = ErrorgapReplayOptions()
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let client = ErrorgapClient(configuration)
        sharedClient = client
        stopReplayLocked()
        if replay ?? replayDefault, (try? configuration.validate()) != nil {
            let recorder = ErrorgapReplayRecorder(
                configuration: configuration,
                session: client.urlSession,
                options: replayOptions
            )
            sharedReplay = recorder
            client.errorObserver = { [weak recorder] label in
                recorder?.errorStarted(label) ?? { _ in }
            }
            let center = NotificationCenter.default
            lifecycleObservers = [
                center.addObserver(forName: didEnterBackground, object: nil, queue: nil) { _ in
                    Errorgap.appPaused()
                },
                center.addObserver(forName: willEnterForeground, object: nil, queue: nil) { _ in
                    Errorgap.appResumed()
                },
            ]
            recorder.start()
        }
        if captureGlobals {
            #if canImport(ObjectiveC)
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler(uncaughtTrampoline)
            #endif
            // Fatal signals and Swift runtime traps, reported on the next
            // launch (needs `crashDirectory`).
            client.captureSignals()
        }
        // Crashes the last launch could not deliver.
        if configuration.crashDirectory != nil, let client = sharedClient {
            DispatchQueue.global(qos: .utility).async { client.sendStoredCrashes() }
        }
    }

    @discardableResult
    public static func notify(
        _ error: Error,
        options: NoticeOptions = NoticeOptions()
    ) -> DeliveryResult {
        guard let client = sharedClient else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.notInitialized, queued: false)
        }
        return client.notify(error, options: options)
    }

    @discardableResult
    public static func notifyTransaction(
        _ transaction: ErrorgapTransaction
    ) -> DeliveryResult {
        guard let client = sharedClient else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.notInitialized, queued: false)
        }
        return client.notifyTransaction(transaction)
    }

    @discardableResult
    public static func notifyLog(
        _ message: String,
        level: String = "info",
        source: String? = nil
    ) -> DeliveryResult {
        guard let client = sharedClient else {
            return DeliveryResult(status: nil, body: nil, error: ErrorgapError.notInitialized, queued: false)
        }
        return client.notifyLog(message, level: level, source: source)
    }

    public static func trackJob<T>(
        _ jobClass: String,
        queue: String = "default",
        operation: (ErrorgapSpanCollector) throws -> T
    ) rethrows -> T {
        guard let client = sharedClient else {
            return try operation(ErrorgapSpanCollector())
        }
        return try client.trackJob(jobClass, queue: queue, operation: operation)
    }

    public static func flush(timeout: TimeInterval = 5) {
        sharedClient?.flush(timeout: timeout)
    }

    // MARK: - Session replay

    /// Record the screen now showing in the session replay timeline. In
    /// SwiftUI, `.errorgapScreen("Checkout")` calls it when the view appears.
    public static func trackScreen(_ name: String) {
        currentReplay()?.screen(name)
    }

    /// The app went to the background. Called for you on iOS and tvOS; call
    /// it yourself elsewhere.
    public static func appPaused() {
        currentReplay()?.paused()
    }

    /// The app is in the foreground again. Called for you on iOS and tvOS.
    public static func appResumed() {
        currentReplay()?.resumed()
    }

    /// Record an API call in the session replay timeline when it failed or
    /// answered 5xx. Call it from your URLSession completion handlers.
    public static func recordCall(_ request: URLRequest, response: URLResponse?, error: Error?) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error != nil || status == 0 || status >= 500 else { return }
        currentReplay()?.apiError(method: request.httpMethod ?? "GET", url: request.url, status: status)
    }

    private static var replayDefault: Bool {
        #if os(iOS) || os(tvOS)
        return true
        #else
        return false
        #endif
    }

    private static func currentReplay() -> ErrorgapReplayRecorder? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sharedReplay
    }

    /// Called with `stateLock` held.
    private static func stopReplayLocked() {
        sharedReplay?.stop()
        sharedReplay = nil
        for observer in lifecycleObservers { NotificationCenter.default.removeObserver(observer) }
        lifecycleObservers = []
    }

    // For tests: reset the singleton.
    static func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        sharedClient = nil
        stopReplayLocked()
    }
}
