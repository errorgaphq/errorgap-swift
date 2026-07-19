import Foundation

public struct NoticeOptions {
    public var context: [String: Any]?
    public var environment: [String: Any]?
    public var session: [String: Any]?
    public var params: [String: Any]?
    public var backtrace: [ErrorgapBacktraceFrame]?

    public init(
        context: [String: Any]? = nil,
        environment: [String: Any]? = nil,
        session: [String: Any]? = nil,
        params: [String: Any]? = nil,
        backtrace: [ErrorgapBacktraceFrame]? = nil
    ) {
        self.context = context
        self.environment = environment
        self.session = session
        self.params = params
        self.backtrace = backtrace
    }
}

enum Notice {
    static let notifierId = "errorgap-swift"

    static func build(
        error: Error,
        config: ErrorgapConfiguration,
        options: NoticeOptions = NoticeOptions()
    ) -> [String: Any] {
        var defaultContext: [String: Any] = [
            "notifier": notifierId,
            "notifier_version": ErrorgapVersion.current,
            "environment": config.environment,
        ]
        if let release = config.release {
            defaultContext["release"] = release
        }
        if let rootDirectory = config.rootDirectory {
            defaultContext["root_directory"] = rootDirectory
        }
        if let extraContext = options.context {
            defaultContext.merge(extraContext) { _, new in new }
        }

        var defaultEnvironment = DeviceInfo.capture()
        defaultEnvironment.merge(config.deviceInfo) { _, new in new }
        if let extraEnv = options.environment {
            defaultEnvironment.merge(extraEnv) { _, new in new }
        }

        let typeName = String(describing: type(of: error))
        let message = errorMessage(error)

        let errorEntry: [String: Any] = [
            "type": typeName,
            "message": message,
            "backtrace": Backtrace.fromError(
                error,
                rootDirectory: config.rootDirectory,
                inAppModules: config.inAppModules,
                frames: options.backtrace
            ),
        ]

        var notice: [String: Any] = [
            "received_at": errorgapTimestamp(),
            "errors": [errorEntry],
            "context": defaultContext,
            "environment": defaultEnvironment,
            "session": options.session ?? [:],
            "params": Filter.params(options.params ?? [:], filterKeys: config.filterKeys),
        ]
        if let pid = config.projectId {
            notice["project_id"] = pid
        }
        return notice
    }

    private static func errorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        if type(of: error) == NSError.self {
            return (error as NSError).localizedDescription
        }
        return String(describing: error)
    }
}

extension ISO8601DateFormatter {
    static let errorgapFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
