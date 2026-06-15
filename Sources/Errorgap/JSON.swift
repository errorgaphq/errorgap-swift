import Foundation

enum JSON {
    /// Encode the loose `[String: Any]` notice envelope using Foundation's
    /// `JSONSerialization`. Returns `nil` if the payload contains a type the
    /// system can't serialize.
    static func encode(_ object: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(object) else {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: object, options: [])
    }
}
