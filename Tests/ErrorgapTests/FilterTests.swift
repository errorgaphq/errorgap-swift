import Testing
@testable import Errorgap

struct FilterTests {
    let defaults = ["password", "token", "secret", "api_key", "authorization", "cookie"]

    @Test func masksFilteredKeys() {
        let out = Filter.params([
            "username": "alice",
            "password": "hunter2",
            "access_token": "x",
        ], filterKeys: defaults)
        #expect(out["username"] as? String == "alice")
        #expect(out["password"] as? String == "[FILTERED]")
        #expect(out["access_token"] as? String == "[FILTERED]")
    }

    @Test func recursesIntoNestedDictionaries() {
        let out = Filter.params([
            "user": ["name": "alice", "api_key": "x"] as [String: Any],
        ], filterKeys: defaults)
        let user = out["user"] as? [String: Any]
        #expect(user?["name"] as? String == "alice")
        #expect(user?["api_key"] as? String == "[FILTERED]")
    }

    @Test func caseInsensitive() {
        let out = Filter.params(["Authorization": "Bearer xyz"], filterKeys: defaults)
        #expect(out["Authorization"] as? String == "[FILTERED]")
    }
}
