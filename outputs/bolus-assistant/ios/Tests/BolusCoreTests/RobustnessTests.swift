import XCTest
@testable import BolusCore

/// Hostile or unusual input must never crash the app or silently change stored data.
final class RobustnessTests: XCTestCase {
    func testTextLikeNaNStaysText() throws {
        let entry = try EntryFactory(now: referenceInstant, timeZone: TimeZone(identifier: "UTC")!)
            .batch(.init(occurredAt: referenceInstant, note: "NaN"), profiles: []).entries[0]
        let restored = BolusJSON.value(BolusJSON.data(entry.data))
        XCTAssertEqual(restored.string("note"), "NaN")
        XCTAssertEqual(BolusJSON.value(Data(#"{"a":"Infinity","b":"-Infinity","c":1.5}"#.utf8)),
                       .object(["a": .string("Infinity"), "b": .string("-Infinity"), "c": .number(1.5)]))
    }

    func testBackupWithAbsurdSchemaVersionIsRejected() {
        for version in ["1e300", "2.5", "-1", "0"] {
            let data = Data(#"{"schemaVersion":\#(version),"format":"bolus-local-backup"}"#.utf8)
            XCTAssertThrowsError(try BackupMigrator.decode(data), version)
        }
    }

    func testTokenCountFromProviderIsBounded() {
        func record(_ usage: JSONValue) -> AIInsightRecord {
            AIInsightRecord(question: "q", response: .object([:]), context: .object([:]), provider: "openai", model: "m", usage: usage)
        }
        XCTAssertEqual(record(.object(["total_tokens": .number(1234)])).totalTokens, 1234)
        XCTAssertEqual(record(.object(["total_tokens": .number(1e300)])).totalTokens, 0)
        XCTAssertEqual(record(.object(["total_tokens": .number(-5)])).totalTokens, 0)
        XCTAssertEqual(record(.object(["total_tokens": .string("NaN")])).totalTokens, 0)
        XCTAssertEqual(record(.object([:])).totalTokens, 0)
    }

    func testUSDAResponseWithAbsurdIdentifiersIsSkipped() throws {
        let body = #"""
        {"foods":[
          {"fdcId":1e300,"description":"Huge","foodNutrients":[{"nutrientId":1005,"value":10}]},
          {"fdcId":171705,"description":"Rice","foodNutrients":[{"nutrientId":1e300,"value":1},{"nutrientId":1005,"value":28.2}]}
        ]}
        """#
        let parsed = try USDACatalog.parse(HTTPResponseData(status: 200, body: Data(body.utf8)))
        XCTAssertEqual(parsed.foods.map(\.externalID), ["171705"])
        XCTAssertEqual(parsed.foods.first?.carbs, 28.2)
        XCTAssertEqual(parsed.skipped, 1)
    }
}
