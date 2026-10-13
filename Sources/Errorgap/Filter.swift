import Foundation

enum Filter {
    static let filteredValue = "[FILTERED]"

    static let truncatedValue = "[TRUNCATED]"
    private static let maxString = 4096
    private static let maxItems = 128
    private static let maxDepth = 8

    /// Mask sensitive keys at any depth (inside arrays too) and cut long
    /// strings and large or deeply nested collections.
    static func params(_ value: [String: Any], filterKeys: [String]) -> [String: Any] {
        let lowered = filterKeys.map { $0.lowercased() }
        return walkMap(value, lowered: lowered, depth: 0)
    }

    private static func walkMap(_ value: [String: Any], lowered: [String], depth: Int) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, val) in value {
            if out.count >= maxItems { break }
            out[key] = isSensitive(key, lowered: lowered) ? filteredValue : walk(val, lowered: lowered, depth: depth + 1)
        }
        return out
    }

    private static func walk(_ value: Any, lowered: [String], depth: Int) -> Any {
        if let text = value as? String {
            return text.count > maxString ? String(text.prefix(maxString)) + truncatedValue : text
        }
        if let nested = value as? [String: Any] {
            return depth >= maxDepth ? truncatedValue : walkMap(nested, lowered: lowered, depth: depth)
        }
        if let items = value as? [Any] {
            if depth >= maxDepth { return truncatedValue }
            return items.prefix(maxItems).map { walk($0, lowered: lowered, depth: depth + 1) }
        }
        return value
    }

    private static func isSensitive(_ key: String, lowered: [String]) -> Bool {
        let lk = key.lowercased()
        return lowered.contains { !$0.isEmpty && lk.contains($0) }
    }
}
