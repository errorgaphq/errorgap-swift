import Testing
@testable import Errorgap

struct ConfigurationTests {
    @Test func defaultsWhenNothingProvided() {
        let cfg = ErrorgapConfiguration()
        #expect(!cfg.endpoint.isEmpty)
        #expect(cfg.async)
        #expect(cfg.filterKeys.contains("password"))
        #expect(!cfg.apmEnabled)
        #expect(!cfg.logsEnabled)
        #expect(cfg.apmSampleRate == 1)
    }

    @Test func validateThrowsWhenProjectSlugMissing() {
        let cfg = ErrorgapConfiguration(projectSlug: nil)
        #expect(throws: ErrorgapError.missingProjectSlug) {
            try cfg.validate()
        }
    }

    @Test func validatePassesWhenProjectSlugPresent() throws {
        let cfg = ErrorgapConfiguration(projectSlug: "demo")
        try cfg.validate()
    }

    @Test func validatesQueueAndTimeout() {
        #expect(throws: ErrorgapError.invalidQueueSize) {
            try ErrorgapConfiguration(projectSlug: "demo", queueSize: 0).validate()
        }
        #expect(throws: ErrorgapError.invalidTimeout) {
            try ErrorgapConfiguration(projectSlug: "demo", timeout: 0).validate()
        }
    }
}
