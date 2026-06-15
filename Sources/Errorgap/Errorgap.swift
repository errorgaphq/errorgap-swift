import Foundation

// Module-level state read from the C uncaught-exception handler trampoline.
// nonisolated(unsafe) lets us touch these from a C callback without
// Sendable/MainActor friction; access from Swift is gated through stateLock.
nonisolated(unsafe) private var sharedClient: ErrorgapClient?
nonisolated(unsafe) private var previousHandler: (@convention(c) (NSException) -> Void)?
private let stateLock = NSLock()

private let uncaughtTrampoline: @convention(c) (NSException) -> Void = { exception in
    let userInfo: [String: Any] = [
        "callStackSymbols": exception.callStackSymbols,
        NSLocalizedDescriptionKey: exception.reason ?? exception.name.rawValue,
    ]
    let nsError = NSError(domain: "io.errorgap.uncaught", code: 0, userInfo: userInfo)
    _ = sharedClient?.notify(nsError, options: NoticeOptions(context: [
        "source": "NSSetUncaughtExceptionHandler",
        "exception_name": exception.name.rawValue,
    ]), sync: true)
    if let prev = previousHandler {
        prev(exception)
    }
}

public enum Errorgap {
    public static func initialize(_ configuration: ErrorgapConfiguration, captureGlobals: Bool = true) {
        stateLock.lock()
        defer { stateLock.unlock() }
        sharedClient = ErrorgapClient(configuration)
        if captureGlobals {
            previousHandler = NSGetUncaughtExceptionHandler()
            NSSetUncaughtExceptionHandler(uncaughtTrampoline)
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

    public static func flush(timeout: TimeInterval = 5) {
        sharedClient?.flush(timeout: timeout)
    }

    // For tests: reset the singleton.
    static func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        sharedClient = nil
    }
}
