import XCTest
@testable import BolusCore

final class PreferencesTests: XCTestCase {
    func testPetsAndThemes() {
        XCTAssertEqual(AppPreferences.mascots.map(\.id), ["cat", "siamese", "pig", "dinosaur", "frog", "otter", "panda"])
        XCTAssertTrue(AppPreferences.themes.contains { $0.id == "lilac" })
        XCTAssertFalse(AppPreferences.mascots.contains { $0.id == "rabbit" })
    }

    func testRabbitBecomesFrogAndNewSettingsRoundTrip() throws {
        let legacy = try BolusJSON.decoder.decode(AppPreferences.self, from: Data(#"{"name":"Мария","mascot_id":"rabbit","theme_id":"pink"}"#.utf8))
        XCTAssertEqual(legacy.mascotID, "frog")
        XCTAssertFalse(legacy.healthAutoSync)
        XCTAssertFalse(legacy.iconFollowsTheme)
        XCTAssertNil(legacy.healthLastSync)

        var prefs = AppPreferences(themeID: "lilac", mascotID: "siamese")
        prefs.iconFollowsTheme = true
        prefs.healthAutoSync = true
        prefs.healthLastSync = ISODate.parse("2026-10-04T08:30:00.250000+00:00")
        let restored = try BolusJSON.decoder.decode(AppPreferences.self, from: try BolusJSON.encoder.encode(prefs))
        XCTAssertEqual(restored, prefs)
    }
}
