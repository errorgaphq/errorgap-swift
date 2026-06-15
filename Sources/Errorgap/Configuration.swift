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
    public var async: Bool
    public var filterKeys: [String]
    public var timeout: TimeInterval
    public var queueSize: Int

    public init(
        endpoint: String? = nil,
        projectSlug: String? = nil,
        projectId: String? = nil,
        apiKey: String? = nil,
        environment: String? = nil,
        release: String? = nil,
        async: Bool = true,
        filterKeys: [String] = ErrorgapConfiguration.defaultFilterKeys,
        timeout: TimeInterval = 5,
        queueSize: Int = 100
    ) {
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
        self.async = async
        self.filterKeys = filterKeys
        self.timeout = timeout
        self.queueSize = queueSize
    }

    func validate() throws {
        guard let slug = projectSlug, !slug.isEmpty else {
            throw ErrorgapError.missingProjectSlug
        }
        guard !endpoint.isEmpty else {
            throw ErrorgapError.missingEndpoint
        }
    }
}

public enum ErrorgapError: Error, Equatable {
    case missingProjectSlug
    case missingEndpoint
    case notInitialized
    case queueFull
    case encoding
}
