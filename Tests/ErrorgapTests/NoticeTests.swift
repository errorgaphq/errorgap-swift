import Foundation
import Testing
@testable import Errorgap

struct NoticeTests {
    private func cfg() -> ErrorgapConfiguration {
        ErrorgapConfiguration(projectSlug: "demo", projectId: "p_1", environment: "test", release: "1.2.3")
    }

    @Test func capturesTypeAndMessage() {
        struct CustomError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let notice = Notice.build(error: CustomError(), config: cfg())
        let errors = notice["errors"] as! [[String: Any]]
        #expect(errors[0]["type"] as? String == "CustomError")
        #expect(errors[0]["message"] as? String == "boom")
    }

    @Test func includesNotifierIdentification() {
        let notice = Notice.build(error: NSError(domain: "test", code: 0), config: cfg())
        let ctx = notice["context"] as! [String: Any]
        #expect(ctx["notifier"] as? String == "errorgap-swift")
        #expect(ctx["notifier_version"] as? String == ErrorgapVersion.current)
        #expect(ctx["environment"] as? String == "test")
        #expect(ctx["release"] as? String == "1.2.3")
    }

    @Test func filtersSensitiveParams() {
        let options = NoticeOptions(params: ["username": "alice", "password": "hunter2"])
        let notice = Notice.build(error: NSError(domain: "test", code: 0), config: cfg(), options: options)
        let params = notice["params"] as! [String: Any]
        #expect(params["username"] as? String == "alice")
        #expect(params["password"] as? String == "[FILTERED]")
    }

    @Test func includesProjectId() {
        let notice = Notice.build(error: NSError(domain: "test", code: 0), config: cfg())
        #expect(notice["project_id"] as? String == "p_1")
    }

    @Test func sendsNSErrorMessagesAndRawFramesInTheIngestionSchema() {
        let error = NSError(
            domain: "io.errorgap.test",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey: "raw crash message",
                "callStackSymbols": ["0 TestApp 0x000000 TestApp.worker + 42"],
            ]
        )
        let notice = Notice.build(error: error, config: cfg())
        let errors = notice["errors"] as! [[String: Any]]
        let frames = errors[0]["backtrace"] as! [[String: Any]]

        #expect(errors[0]["message"] as? String == "raw crash message")
        #expect(frames[0]["file"] as? String == "<unknown>")
        #expect(frames[0]["function"] as? String == "0 TestApp 0x000000 TestApp.worker + 42")
    }

    @Test func preservesPlainSwiftErrorCaseMessages() {
        enum PlainError: Error { case exploded }
        let notice = Notice.build(error: PlainError.exploded, config: cfg())
        let errors = notice["errors"] as! [[String: Any]]
        #expect(errors[0]["message"] as? String == "exploded")
    }
}
