import Foundation

/// The APM transaction the current task is running in, so errors reported
/// during it carry its id as `context.transaction_id` and errorgap links each
/// error to the interaction that raised it.
///
/// A `@TaskLocal`: it flows into child tasks and synchronous code inside
/// `withTransaction`, and never leaks into a concurrent task.
public enum ErrorgapTransactionContext {
    @TaskLocal public static var current: String?
}

/// Run `operation` as part of the transaction with `id`.
public func withErrorgapTransaction<T>(_ id: String, operation: () throws -> T) rethrows -> T {
    try ErrorgapTransactionContext.$current.withValue(id, operation: operation)
}

/// Run async `operation` as part of the transaction with `id`.
public func withErrorgapTransaction<T>(_ id: String, operation: () async throws -> T) async rethrows -> T {
    try await ErrorgapTransactionContext.$current.withValue(id, operation: operation)
}
