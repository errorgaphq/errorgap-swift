import Foundation

enum Filter {
    static let filteredValue = "[FILTERED]"

    static func params(_ value: [String: Any], filterKeys: [String]) -> [String: Any] {
        let lowered = filterKeys.map { $0.lowercased() }
        return walk(value, lowered: lowered)
    }

    private static func walk(_ value: [String: Any], lowered: [String]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, val) in value {
            if isSensitive(key, lowered: lowered) {
                out[key] = filteredValue
            } else if let nested = val as? [String: Any] {
                out[key] = walk(nested, lowered: lowered)
            } else {
                out[key] = val
            }
        }
        return out
    }

    private static func isSensitive(_ key: String, lowered: [String]) -> Bool {
        let lk = key.lowercased()
        return lowered.contains { lk.contains($0) }
    }
}
