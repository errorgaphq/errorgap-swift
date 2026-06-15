import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum DeviceInfo {
    static func capture() -> [String: Any] {
        var info: [String: Any] = [
            "os_name": osName(),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]
        if let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            info["app_version"] = appVersion
        }
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            info["app_build"] = build
        }
        if let bundleId = Bundle.main.bundleIdentifier {
            info["bundle_id"] = bundleId
        }

        #if canImport(UIKit)
        let device = UIDevice.current
        info["device_model"] = device.model
        info["device_name"] = device.name
        #endif

        return info
    }

    private static func osName() -> String {
        #if os(iOS)
        return "iOS"
        #elseif os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #else
        return "unknown"
        #endif
    }
}
