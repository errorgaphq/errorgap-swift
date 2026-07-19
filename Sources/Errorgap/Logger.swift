import Foundation

/// Lightweight structured logger that forwards through the configured
/// Errorgap client without requiring a third-party logging dependency.
public struct ErrorgapLogger {
    public let source: String?

    public init(source: String? = nil) {
        self.source = source
    }

    @discardableResult
    public func log(_ message: String, level: String = "info") -> DeliveryResult {
        Errorgap.notifyLog(message, level: level, source: source)
    }

    @discardableResult public func warning(_ message: String) -> DeliveryResult {
        log(message, level: "warn")
    }

    @discardableResult public func error(_ message: String) -> DeliveryResult {
        log(message, level: "error")
    }
}
