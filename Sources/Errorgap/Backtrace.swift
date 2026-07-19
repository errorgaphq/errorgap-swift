import Foundation

public struct ErrorgapBacktraceFrame {
    public let file: String?
    public let line: Int?
    public let function: String
    public let inApp: Bool

    public init(
        file: String? = #filePath,
        line: Int? = #line,
        function: String = #function,
        inApp: Bool = true
    ) {
        self.file = file
        self.line = line
        self.function = function
        self.inApp = inApp
    }
}

/// Adopt this protocol on an Error type when source-aware file and line
/// frames are available. Raw runtime frames remain the fallback for crashes
/// that require dSYM symbolication.
public protocol ErrorgapBacktraceProviding {
    var errorgapBacktrace: [ErrorgapBacktraceFrame] { get }
}

public enum Backtrace {
    private static let contextRadius = 6
    private static let maximumSourceBytes = 2 * 1024 * 1024
    private static let maximumLineLength = 400

    /// Capture an unsymbolicated stack trace from the current call site.
    /// Frames carry the raw `Thread.callStackSymbols` line because runtime
    /// dSYM symbolication is out of scope; the server resolves these by
    /// matching against an uploaded dSYM bundle.
    public static func capture(inAppModules: [String] = []) -> [[String: Any]] {
        let symbols = Thread.callStackSymbols
        return symbols.enumerated().map { index, raw in
            [
                "file": "<unknown>",
                "function": raw,
                "in_app": NSNumber(value: isInApp(raw, modules: inAppModules)),
                "index": NSNumber(value: index),
            ] as [String: Any]
        }
    }

    /// Extract a backtrace from an `NSError` userInfo dictionary if present
    /// (e.g. set via `NSException.callStackSymbols`); falls back to the
    /// current call stack.
    public static func fromError(
        _ error: Error,
        rootDirectory: String? = nil,
        inAppModules: [String] = [],
        frames: [ErrorgapBacktraceFrame]? = nil
    ) -> [[String: Any]] {
        let sourceFrames = frames ?? (error as? ErrorgapBacktraceProviding)?.errorgapBacktrace
        if let sourceFrames, !sourceFrames.isEmpty {
            return sourceFrames.enumerated().map { index, frame in
                payload(frame, index: index, rootDirectory: rootDirectory)
            }
        }
        if let nsError = error as NSError?,
           let symbols = nsError.userInfo["callStackSymbols"] as? [String]
        {
            return symbols.enumerated().map { index, raw in
                return [
                    "file": "<unknown>",
                    "function": raw,
                    "in_app": NSNumber(value: isInApp(raw, modules: inAppModules)),
                    "index": NSNumber(value: index),
                ] as [String: Any]
            }
        }
        return capture(inAppModules: inAppModules)
    }

    private static func payload(
        _ frame: ErrorgapBacktraceFrame,
        index: Int,
        rootDirectory: String?
    ) -> [String: Any] {
        let normalizedFile = frame.file.map { normalizedPath($0, rootDirectory: rootDirectory) }
        let lineValue: Any = frame.line.map { NSNumber(value: $0) as Any } ?? NSNull()
        var result: [String: Any] = [
            "file": normalizedFile ?? "<unknown>",
            "line": lineValue,
            "function": frame.function,
            "in_app": NSNumber(value: frame.inApp),
            "index": NSNumber(value: index),
        ]
        if let file = frame.file,
           let line = frame.line,
           let source = source(file: file, line: line, rootDirectory: rootDirectory)
        {
            result["source"] = source
        }
        return result
    }

    private static func isInApp(_ symbol: String, modules: [String]) -> Bool {
        if symbol.contains("Errorgap") || symbol.contains("Foundation") || symbol.contains("libswift") {
            return false
        }
        return modules.isEmpty || modules.contains { symbol.contains($0) }
    }

    private static func normalizedPath(_ file: String, rootDirectory: String?) -> String {
        guard let rootDirectory, !rootDirectory.isEmpty else { return file }
        let root = URL(fileURLWithPath: rootDirectory).standardizedFileURL.path
        let path = URL(fileURLWithPath: file).standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : file
    }

    private static func source(
        file: String,
        line: Int,
        rootDirectory: String?
    ) -> [String: Any]? {
        guard line > 0 else { return nil }
        let candidates = sourceCandidates(file: file, rootDirectory: rootDirectory)
        guard let content = candidates.lazy.compactMap(readSource).first else { return nil }
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return nil }
        let target = min(max(line - 1, 0), lines.count - 1)
        let start = max(target - contextRadius, 0)
        let end = min(target + contextRadius + 1, lines.count)
        return [
            "start_line": NSNumber(value: start + 1),
            "lines": lines[start..<end].map { value in
                value.count > maximumLineLength ? String(value.prefix(maximumLineLength)) : value
            },
        ]
    }

    private static func sourceCandidates(file: String, rootDirectory: String?) -> [URL] {
        var candidates: [URL] = []
        if file.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: file))
        }
        if let rootDirectory, !rootDirectory.isEmpty {
            let root = URL(fileURLWithPath: rootDirectory)
            candidates.append(root.appendingPathComponent(file))
            candidates.append(root.appendingPathComponent("Sources").appendingPathComponent(file))
            candidates.append(root.appendingPathComponent("Tests").appendingPathComponent(file))
        }
        return candidates
    }

    private static func readSource(_ url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumSourceBytes
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
