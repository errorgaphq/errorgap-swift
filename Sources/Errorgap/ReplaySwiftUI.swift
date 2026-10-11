#if canImport(SwiftUI)
import SwiftUI

@available(iOS 14.0, macOS 11.0, tvOS 14.0, watchOS 7.0, *)
public extension View {
    /// Records this screen in the session replay timeline when it appears.
    func errorgapScreen(_ name: String) -> some View {
        onAppear { Errorgap.trackScreen(name) }
    }
}
#endif
