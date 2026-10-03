import XCTest
@testable import BolusCore
final class BolusCoreTests: XCTestCase {
    func testServerAddressBoundary() {
        for value in ["https://diary.example.com", "http://localhost:8080", "http://192.168.1.3:8080", "http://mac.local:8080"] { XCTAssertNotNil(ServerAddress.parse(value)) }
        for value in ["http://example.com", "https://user:pass@example.com", "https://example.com?key=x", "https://example.com/path", "file:///etc/passwd", "javascript:alert(1)", "http://192.168.999.2", "http://10.1.example.2.3", "http://192..168.1.2"] { XCTAssertNil(ServerAddress.parse(value)) }
    }
    func testCookiesStayOnConfiguredOrigin() {
        let server = URL(string: "https://diary.example.com")!
        XCTAssertTrue(ServerAddress.sameOrigin(server, URL(string: "https://diary.example.com:443/api/users/me")!))
        XCTAssertFalse(ServerAddress.sameOrigin(server, URL(string: "http://diary.example.com")!))
        XCTAssertFalse(ServerAddress.sameOrigin(server, URL(string: "https://other.example.com")!))
        XCTAssertFalse(ServerAddress.sameOrigin(server, URL(string: "https://diary.example.com:444")!))
    }
    func testUnavailableHealthDataIsOmitted() throws {
        var day = HealthDay(date: "2026-10-03")
        XCTAssertFalse(day.hasData); day.steps = 123; XCTAssertTrue(day.hasData)
        let body = HealthPayload(userID: "owner", timezone: "Europe/Moscow", workouts: [], days: [day])
        let data = try JSONEncoder().encode(body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let days = try XCTUnwrap(json["days"] as? [[String: Any]])
        XCTAssertEqual(days[0]["steps"] as? Int, 123)
        XCTAssertNil(days[0]["exercise_minutes"])
        XCTAssertEqual(json["expected_user_id"] as? String, "owner")
        XCTAssertNil(json["insulin"])
    }
}
