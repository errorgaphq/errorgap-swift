import Testing
@testable import Errorgap

struct ConfigurationTests {
    @Test func defaultsWhenNothingProvided() {
        let cfg = ErrorgapConfiguration()
        #expect(!cfg.endpoint.isEmpty)
        #expect(cfg.async)
        #expect(cfg.filterKeys.contains("password"))
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
}
