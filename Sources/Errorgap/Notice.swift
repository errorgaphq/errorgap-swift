import Foundation

public struct NoticeOptions {
    public var context: [String: Any]?
    public var environment: [String: Any]?
    public var session: [String: Any]?
    public var params: [String: Any]?

    public init(
        context: [String: Any]? = nil,
        environment: [String: Any]? = nil,
        session: [String: Any]? = nil,
        params: [String: Any]? = nil
    ) {
        self.context = context
        self.environment = environment
        self.session = session
        self.params = params
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
        if let extraContext = options.context {
            defaultContext.merge(extraContext) { _, new in new }
        }

        var defaultEnvironment = DeviceInfo.capture()
        if let extraEnv = options.environment {
            defaultEnvironment.merge(extraEnv) { _, new in new }
        }

        let typeName = String(describing: type(of: error))
        let message = errorMessage(error)

        let errorEntry: [String: Any] = [
            "type": typeName,
            "message": message,
            "backtrace": Backtrace.fromError(error),
        ]

        var notice: [String: Any] = [
            "received_at": ISO8601DateFormatter.errorgapFormatter.string(from: Date()),
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
