import Foundation

public enum Backtrace {
    /// Capture an unsymbolicated stack trace from the current call site.
    /// Frames carry the raw `Thread.callStackSymbols` line because runtime
    /// dSYM symbolication is out of scope; the server resolves these by
    /// matching against an uploaded dSYM bundle.
    public static func capture() -> [[String: Any]] {
        let symbols = Thread.callStackSymbols
        return symbols.enumerated().map { index, raw in
            return [
                "file": NSNull(),
                "function": raw,
                "in_app": NSNumber(value: !raw.contains("Errorgap")),
                "index": NSNumber(value: index),
            ] as [String: Any]
        }
    }

    /// Extract a backtrace from an `NSError` userInfo dictionary if present
    /// (e.g. set via `NSException.callStackSymbols`); falls back to the
    /// current call stack.
    public static func fromError(_ error: Error) -> [[String: Any]] {
        if let nsError = error as NSError?,
           let symbols = nsError.userInfo["callStackSymbols"] as? [String]
        {
            return symbols.enumerated().map { index, raw in
                return [
                    "file": NSNull(),
                    "function": raw,
                    "in_app": NSNumber(value: !raw.contains("Errorgap")),
                    "index": NSNumber(value: index),
                ] as [String: Any]
            }
        }
        return capture()
    }
}
