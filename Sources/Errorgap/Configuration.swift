import Foundation

public struct ErrorgapConfiguration {
    public static let defaultFilterKeys: [String] = [
        "password", "password_confirmation", "token", "secret",
        "api_key", "authorization", "cookie",
    ]

    public var endpoint: String
    public var projectSlug: String?
    public var projectId: String?
    public var apiKey: String?
    public var environment: String
    public var release: String?
    public var rootDirectory: String?
    public var inAppModules: [String]
    public var async: Bool
    public var filterKeys: [String]
    public var timeout: TimeInterval
    public var queueSize: Int
    public var apmEnabled: Bool
    public var apmSampleRate: Double
    public var logsEnabled: Bool
    public var minimumLogLevel: String
    public var deviceInfo: [String: Any]
    /// Environments in which nothing is sent.
    public var ignoreEnvironments: [String]
    /// Sees each notice before it is sent and returns the notice to send,
    /// changed or not, or `nil` to drop it.
    public var beforeNotify: (([String: Any]) -> [String: Any]?)?
    /// Where an uncaught exception is kept until it is delivered, so one
    /// that ends the app before the request finishes is sent on the next
    /// launch. For an app, a folder in the caches directory.
    public var crashDirectory: String?

    /// True when nothing should be sent from the configured environment.
    public var ignoredEnvironment: Bool { ignoreEnvironments.contains(environment) }

    public init(
        endpoint: String? = nil,
        projectSlug: String? = nil,
        projectId: String? = nil,
        apiKey: String? = nil,
        environment: String? = nil,
        release: String? = nil,
        rootDirectory: String? = FileManager.default.currentDirectoryPath,
        inAppModules: [String] = [],
        async: Bool = true,
        filterKeys: [String] = ErrorgapConfiguration.defaultFilterKeys,
        timeout: TimeInterval = 5,
        queueSize: Int = 100,
        apmEnabled: Bool? = nil,
        apmSampleRate: Double? = nil,
        logsEnabled: Bool? = nil,
        minimumLogLevel: String? = nil,
        deviceInfo: [String: Any] = [:],
        ignoreEnvironments: [String]? = nil,
        beforeNotify: (([String: Any]) -> [String: Any]?)? = nil,
        crashDirectory: String? = nil
    ) {
        self.ignoreEnvironments = ignoreEnvironments
            ?? (ProcessInfo.processInfo.environment["ERRORGAP_IGNORE_ENVIRONMENTS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        self.beforeNotify = beforeNotify
        self.crashDirectory = crashDirectory
        self.endpoint = endpoint
            ?? ProcessInfo.processInfo.environment["ERRORGAP_ENDPOINT"]
            ?? "http://127.0.0.1:3030"
        self.projectSlug = projectSlug
            ?? ProcessInfo.processInfo.environment["ERRORGAP_PROJECT_SLUG"]
        self.projectId = projectId
            ?? ProcessInfo.processInfo.environment["ERRORGAP_PROJECT_ID"]
        self.apiKey = apiKey
            ?? ProcessInfo.processInfo.environment["ERRORGAP_API_KEY"]
        self.environment = environment
            ?? ProcessInfo.processInfo.environment["ERRORGAP_ENVIRONMENT"]
            ?? "production"
        self.release = release
        self.rootDirectory = rootDirectory
        self.inAppModules = inAppModules
        self.async = async
        self.filterKeys = filterKeys
        self.timeout = timeout
        self.queueSize = queueSize
        self.apmEnabled = apmEnabled
            ?? Self.environmentBoolean("ERRORGAP_APM_ENABLED", fallback: false)
        self.apmSampleRate = min(max(
            apmSampleRate
                ?? Double(ProcessInfo.processInfo.environment["ERRORGAP_APM_SAMPLE_RATE"] ?? "")
                ?? 1,
            0
        ), 1)
        self.logsEnabled = logsEnabled
            ?? Self.environmentBoolean("ERRORGAP_LOGS_ENABLED", fallback: false)
        self.minimumLogLevel = minimumLogLevel
            ?? ProcessInfo.processInfo.environment["ERRORGAP_MINIMUM_LOG_LEVEL"]
            ?? "warn"
        self.deviceInfo = deviceInfo
    }

    func validate() throws {
        guard let slug = projectSlug, !slug.isEmpty else {
            throw ErrorgapError.missingProjectSlug
        }
        guard !endpoint.isEmpty else {
            throw ErrorgapError.missingEndpoint
        }
        guard timeout > 0 else {
            throw ErrorgapError.invalidTimeout
        }
        guard queueSize > 0 else {
            throw ErrorgapError.invalidQueueSize
        }
    }

    private static func environmentBoolean(_ key: String, fallback: Bool) -> Bool {
        guard let raw = ProcessInfo.processInfo.environment[key]?.lowercased() else {
            return fallback
        }
        switch raw {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return fallback
        }
    }
}

public enum ErrorgapError: Error, Equatable {
    case missingProjectSlug
    case missingEndpoint
    case notInitialized
    case queueFull
    /// Not sent: the server asked for a pause (`Retry-After`) that has not passed yet.
    case rateLimited
    case encoding
    case invalidTimeout
    case invalidQueueSize
}
