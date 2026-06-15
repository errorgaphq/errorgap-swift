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
}
